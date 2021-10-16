module W =
struct
  module Wasm = Wasm
  include Wasm
  include Wasm.Ast
  include Wasm.Types
  include Wasm.Value
  include Wasm.Operators
  type region = Wasm.Source.region
end


(* Helpers *)

let (@@) = W.Source.(@@)

let i32 = W.I32.of_int_s
let (+%) = Int32.add
let (/%) = Int32.div


(* Compilation context entities *)

type 'a entities = {mutable list : 'a option ref list; mutable cnt : int32}

let make_entities () = {list = []; cnt = 0l}
let get_entities ents = List.rev (List.map (fun r -> Option.get !r) ents.list)

let alloc_entity ents : int32 * 'a option ref =
  let idx = ents.cnt in
  let r = ref None in
  ents.cnt <- idx +% 1l;
  ents.list <- r :: ents.list;
  idx, r

let define_entity r ent =
  r := Some ent

let emit_entity ents ent : int32 =
  let idx, r = alloc_entity ents in
  define_entity r ent;
  idx

let implicit_entity ents : int32 =
  assert (ents.list = []);
  let idx = ents.cnt in
  ents.cnt <- idx +% 1l;
  idx


(* Compilation context *)

module DefTypes = Map.Make(struct type t = W.def_type let compare = compare end)
module Refs = Set.Make(Int32)
module Intrinsics = Map.Make(String)

type internal =
  { types : W.type_ entities;
    globals : W.global entities;
    funcs : W.func entities;
    datas : W.data_segment entities;
    imports : W.import entities;
    exports : W.export entities;
    locals : W.local entities;
    instrs : W.instr entities;
    refs : Refs.t ref;
    data_offset : int32 ref;
    start : W.idx option ref;
    deftypes : int32 DefTypes.t ref;
    intrinsics : int32 Intrinsics.t ref;
  }

type 'a ctxt = {ext : 'a; int : internal}

let make_internal () =
  { types = make_entities ();
    globals = make_entities ();
    funcs = make_entities ();
    datas = make_entities ();
    imports = make_entities ();
    exports = make_entities ();
    locals = make_entities ();
    instrs = make_entities ();
    refs = ref Refs.empty;
    data_offset = ref 0l;
    start = ref None;
    deftypes = ref DefTypes.empty;
    intrinsics = ref Intrinsics.empty;
  }

let make_ctxt ext = {ext; int = make_internal ()}


(* Lookup *)

let lookup_def_type_opt ctxt idx : W.def_type option =
  Option.map W.Source.it !(W.Lib.List32.nth (List.rev ctxt.int.types.list) idx)

let lookup_def_type ctxt idx : W.def_type =
  (Option.get !(W.Lib.List32.nth (List.rev ctxt.int.types.list) idx)).W.Source.it

let lookup_func_type ctxt idx : W.func_type =
  match lookup_def_type ctxt idx with
  | W.(FuncDefType ft) -> ft
  | _ -> assert false

let lookup_param_type ctxt idx i : W.value_type =
  let W.(FuncType (ts, _)) = lookup_func_type ctxt idx in
  W.Lib.List32.nth ts i

let lookup_field_type ctxt idx i : W.value_type =
  match lookup_def_type ctxt idx with
  | W.(StructDefType (StructType fts)) ->
    let W.FieldType (t, _) = W.Lib.List32.nth fts i in
    (match t with
    | W.ValueStorageType t -> t
    | _ -> assert false
    )
  | _ -> assert false

let lookup_ref_field_type ctxt idx i : int32 =
  match lookup_field_type ctxt idx i with
  | W.(RefType (_, DefHeapType (SynVar idx'))) -> idx'
  | _ -> assert false

let lookup_intrinsic ctxt name f : int32 =
  match Intrinsics.find_opt name !(ctxt.int.intrinsics) with
  | Some idx -> idx
  | None ->
    let idx = f () in
    ctxt.int.intrinsics := Intrinsics.add name idx !(ctxt.int.intrinsics);
    idx


(* Emitter *)

let emit_type ctxt at dt : int32 =
  match DefTypes.find_opt dt !(ctxt.int.deftypes) with
  | Some idx -> idx
  | None ->
    let idx = emit_entity ctxt.int.types (dt @@ at) in
    ctxt.int.deftypes := DefTypes.add dt idx !(ctxt.int.deftypes);
    idx

let emit_type_deferred ctxt at : int32 * (W.def_type -> unit) =
  let idx, r = alloc_entity ctxt.int.types in
  idx, fun dt ->
    ctxt.int.deftypes := DefTypes.add dt idx !(ctxt.int.deftypes);
    define_entity r (dt @@ at)

let emit_import ctxt at mname name desc =
  let module_name = W.Utf8.decode mname in
  let item_name = W.Utf8.decode name in
  let idesc = desc @@ at in
  ignore (emit_entity ctxt.int.imports W.({module_name; item_name; idesc} @@ at))

let emit_func_import ctxt at mname name ft =
  let typeidx = emit_type ctxt at W.(FuncDefType ft) in
  emit_import ctxt at mname name W.(FuncImport (typeidx @@ at));
  implicit_entity ctxt.int.funcs

let emit_global_import ctxt at mname name mut t =
  emit_import ctxt at mname name W.(GlobalImport (GlobalType (t, mut)));
  implicit_entity ctxt.int.globals

let emit_export descf ctxt at name idx =
  let name = W.Utf8.decode name in
  let edesc = descf (idx @@ at) @@ at in
  ignore (emit_entity ctxt.int.exports W.({name; edesc} @@ at))

let emit_func_export ctxt = emit_export (fun x -> W.FuncExport x) ctxt
let emit_global_export ctxt = emit_export (fun x -> W.GlobalExport x) ctxt

let emit_param ctxt at : int32 =
  implicit_entity ctxt.int.locals

let emit_local ctxt at t' : int32 =
  emit_entity ctxt.int.locals (t' @@ at)

let emit_global ctxt at mut t' ginit : int32 =
  let gtype = W.GlobalType (t', mut) in
  emit_entity ctxt.int.globals (W.{gtype; ginit} @@ at)

let emit_data ctxt at s : int32 =
  let addr = !(ctxt.int.data_offset) in
  let offset = W.[Const (I32 addr @@ at) @@ at] @@ at in
  let dmode = W.Active {index = 0l @@ at; offset} @@ at in
  let seg = W.{dinit = s; dmode} @@ at in
  ignore (emit_entity ctxt.int.datas seg);
  ctxt.int.data_offset := addr +% i32 (String.length s);
  addr

let emit_instr ctxt at instr =
  ignore (emit_entity ctxt.int.instrs (instr @@ at))

let emit_block ctxt at head bt f =
  let ctxt' = {ctxt with int = {ctxt.int with instrs = make_entities ()}} in
  f ctxt';
  emit_instr ctxt at (head bt (get_entities ctxt'.int.instrs))

let emit_let ctxt at bt ts f =
  let ctxt' = {ctxt with int = {ctxt.int with instrs = make_entities ()}} in
  f ctxt';
  let locals = List.map (fun t -> t @@ at) ts in
  emit_instr ctxt at (W.let_ bt locals (get_entities ctxt'.int.instrs))

let emit_func_deferred ctxt at
  : int32 * ('a ctxt -> W.value_type list -> W.value_type list ->
('a ctxt -> int32 -> unit) -> unit) =
  let idx, func = alloc_entity ctxt.int.funcs in
  idx, fun ctxt ts1' ts2' f ->
    let ft = W.(FuncType (ts1', ts2')) in
    let typeidx = emit_type ctxt at W.(FuncDefType ft) in
    let ctxt' = {ctxt with int =
      {ctxt.int with locals = make_entities (); instrs = make_entities ()}} in
    f ctxt' idx;
    define_entity func (
      { W.ftype = typeidx @@ at;
        W.locals = get_entities ctxt'.int.locals;
        W.body = get_entities ctxt'.int.instrs;
      } @@ at
    )

let emit_func ctxt at ts1' ts2' f : int32 =
  let idx, define = emit_func_deferred ctxt at in
  define ctxt ts1' ts2' f;
  idx

let emit_func_ref ctxt _at idx =
  ctxt.int.refs := Refs.add idx !(ctxt.int.refs)

let emit_start ctxt at idx =
  assert (!(ctxt.int.start) = None);
  ctxt.int.start := Some (idx @@ at)


(* Generation *)

let gen_module ctxt at : W.module_ =
  { W.empty_module with
    W.start = !(ctxt.int.start);
    W.types = get_entities ctxt.int.types;
    W.globals = get_entities ctxt.int.globals;
    W.funcs = get_entities ctxt.int.funcs;
    W.imports = get_entities ctxt.int.imports;
    W.exports = get_entities ctxt.int.exports;
    W.datas = get_entities ctxt.int.datas;
    W.elems =
      if !(ctxt.int.refs) = Refs.empty then [] else W.[
        { etype = (NonNullable, FuncHeapType);
          emode = Declarative @@ at;
          einit = Refs.fold (fun idx consts ->
            ([ref_func (idx @@ at) @@ at] @@ at) :: consts) !(ctxt.int.refs) []
        } @@ at
      ];
    W.memories =
      if get_entities ctxt.int.datas = [] then [] else
      let sz = (!(ctxt.int.data_offset) +% 0xffffl) /% 0x10000l in
      [{W.mtype = W.(MemoryType {min = sz; max = Some sz})} @@ at]
  } @@ at