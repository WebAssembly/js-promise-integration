(*
 * Throughout the implementation we use consistent naming conventions for
 * syntactic elements, associated with the types defined here and in a few
 * other places:
 *
 *   x : idx
 *   v : value
 *   e : instr
 *   f : func
 *   m : module_
 *
 *   t : val_type
 *   s : func_type
 *   c : context / config
 *
 * These conventions mostly follow standard practice in language semantics.
 *)

(* Types *)

open Types
open Pack

type void = Lib.void

type void = Lib.void


(* Operators *)

module IntOp =
struct
  type unop = Clz | Ctz | Popcnt | ExtendS of pack_size
  type binop = Add | Sub | Mul | DivS | DivU | RemS | RemU
             | And | Or | Xor | Shl | ShrS | ShrU | Rotl | Rotr
  type testop = Eqz
  type relop = Eq | Ne | LtS | LtU | GtS | GtU | LeS | LeU | GeS | GeU
  type cvtop = ExtendSI32 | ExtendUI32 | WrapI64
             | TruncSF32 | TruncUF32 | TruncSF64 | TruncUF64
             | TruncSatSF32 | TruncSatUF32 | TruncSatSF64 | TruncSatUF64
             | ReinterpretFloat
end

module FloatOp =
struct
  type unop = Neg | Abs | Ceil | Floor | Trunc | Nearest | Sqrt
  type binop = Add | Sub | Mul | Div | Min | Max | CopySign
  type testop = |
  type relop = Eq | Ne | Lt | Gt | Le | Ge
  type cvtop = ConvertSI32 | ConvertUI32 | ConvertSI64 | ConvertUI64
             | PromoteF32 | DemoteF64
             | ReinterpretInt
end

module I32Op = IntOp
module I64Op = IntOp
module F32Op = FloatOp
module F64Op = FloatOp

module V128Op =
struct
  type itestop = AllTrue
  type iunop = Abs | Neg | Popcnt
  type funop = Abs | Neg | Sqrt | Ceil | Floor | Trunc | Nearest
  type ibinop = Add | Sub | Mul | MinS | MinU | MaxS | MaxU | AvgrU
              | AddSatS | AddSatU | SubSatS | SubSatU | DotS | Q15MulRSatS
              | ExtMulLowS | ExtMulHighS | ExtMulLowU | ExtMulHighU
              | Swizzle | Shuffle of int list | NarrowS | NarrowU
  type fbinop = Add | Sub | Mul | Div | Min | Max | Pmin | Pmax
  type irelop = Eq | Ne | LtS | LtU | LeS | LeU | GtS | GtU | GeS | GeU
  type frelop = Eq | Ne | Lt | Le | Gt | Ge
  type icvtop = ExtendLowS | ExtendLowU | ExtendHighS | ExtendHighU
              | ExtAddPairwiseS | ExtAddPairwiseU
              | TruncSatSF32x4 | TruncSatUF32x4
              | TruncSatSZeroF64x2 | TruncSatUZeroF64x2
  type fcvtop = DemoteZeroF64x2 | PromoteLowF32x4
              | ConvertSI32x4 | ConvertUI32x4
  type ishiftop = Shl | ShrS | ShrU
  type ibitmaskop = Bitmask

  type vtestop = AnyTrue
  type vunop = Not
  type vbinop = And | Or | Xor | AndNot
  type vternop = Bitselect

  type testop = (itestop, itestop, itestop, itestop, void, void) V128.laneop
  type unop = (iunop, iunop, iunop, iunop, funop, funop) V128.laneop
  type binop = (ibinop, ibinop, ibinop, ibinop, fbinop, fbinop) V128.laneop
  type relop = (irelop, irelop, irelop, irelop, frelop, frelop) V128.laneop
  type cvtop = (icvtop, icvtop, icvtop, icvtop, fcvtop, fcvtop) V128.laneop
  type shiftop = (ishiftop, ishiftop, ishiftop, ishiftop, void, void) V128.laneop
  type bitmaskop = (ibitmaskop, ibitmaskop, ibitmaskop, ibitmaskop, void, void) V128.laneop

  type nsplatop = Splat
  type 'a nextractop = Extract of int * 'a
  type nreplaceop = Replace of int

  type splatop = (nsplatop, nsplatop, nsplatop, nsplatop, nsplatop, nsplatop) V128.laneop
  type extractop = (extension nextractop, extension nextractop, unit nextractop, unit nextractop, unit nextractop, unit nextractop) V128.laneop
  type replaceop = (nreplaceop, nreplaceop, nreplaceop, nreplaceop, nreplaceop, nreplaceop) V128.laneop
end

type testop = (I32Op.testop, I64Op.testop, F32Op.testop, F64Op.testop) Values.op
type unop = (I32Op.unop, I64Op.unop, F32Op.unop, F64Op.unop) Values.op
type binop = (I32Op.binop, I64Op.binop, F32Op.binop, F64Op.binop) Values.op
type relop = (I32Op.relop, I64Op.relop, F32Op.relop, F64Op.relop) Values.op
type cvtop = (I32Op.cvtop, I64Op.cvtop, F32Op.cvtop, F64Op.cvtop) Values.op

type vec_testop = (V128Op.testop) Values.vecop
type vec_relop = (V128Op.relop) Values.vecop
type vec_unop = (V128Op.unop) Values.vecop
type vec_binop = (V128Op.binop) Values.vecop
type vec_cvtop = (V128Op.cvtop) Values.vecop
type vec_shiftop = (V128Op.shiftop) Values.vecop
type vec_bitmaskop = (V128Op.bitmaskop) Values.vecop
type vec_vtestop = (V128Op.vtestop) Values.vecop
type vec_vunop = (V128Op.vunop) Values.vecop
type vec_vbinop = (V128Op.vbinop) Values.vecop
type vec_vternop = (V128Op.vternop) Values.vecop
type vec_splatop = (V128Op.splatop) Values.vecop
type vec_extractop = (V128Op.extractop) Values.vecop
type vec_replaceop = (V128Op.replaceop) Values.vecop

type ('t, 'p) memop = {ty : 't; align : int; offset : int32; pack : 'p}
type loadop = (num_type, (pack_size * extension) option) memop
type storeop = (num_type, pack_size option) memop

type vec_loadop = (vec_type, (pack_size * vec_extension) option) memop
type vec_storeop = (vec_type, unit) memop
type vec_laneop = (vec_type, pack_size) memop * int


(* Expressions *)

type var = int32 Source.phrase
type num = Values.num Source.phrase
type vec = Values.vec Source.phrase
type name = int list

type block_type = VarBlockType of idx | ValBlockType of val_type option

type instr = instr' Source.phrase
and instr' =
  | Unreachable                       (* trap unconditionally *)
  | Nop                               (* do nothing *)
  | Drop                              (* forget a value *)
  | Select of val_type list option    (* branchless conditional *)
  | Block of block_type * instr list  (* execute in sequence *)
  | Loop of block_type * instr list   (* loop header *)
  | If of block_type * instr list * instr list   (* conditional *)
  | Br of idx                         (* break to n-th surrounding label *)
  | BrIf of idx                       (* conditional break *)
  | BrTable of idx list * idx         (* indexed break *)
  | BrOnNull of idx                   (* break on type *)
  | BrOnNonNull of idx                (* break on type inverted *)
  | BrOnCast of idx * ref_type * ref_type     (* break on type *)
  | BrOnCastFail of idx * ref_type * ref_type (* break on type inverted *)
  | Return                            (* break from function body *)
  | Call of var                       (* call function *)
  | CallIndirect of var * var         (* call function through table *)
  | LocalGet of var                   (* read local variable *)
  | LocalSet of var                   (* write local variable *)
  | LocalTee of var                   (* write local variable and keep value *)
  | GlobalGet of var                  (* read global variable *)
  | GlobalSet of var                  (* write global variable *)
  | TableGet of var                   (* read table element *)
  | TableSet of var                   (* write table element *)
  | TableSize of var                  (* size of table *)
  | TableGrow of var                  (* grow table *)
  | TableFill of var                  (* fill table range with value *)
  | TableCopy of var * var            (* copy table range *)
  | TableInit of var * var            (* initialize table range from segment *)
  | ElemDrop of var                   (* drop passive element segment *)
  | Load of loadop                    (* read memory at address *)
  | Store of storeop                  (* write memory at address *)
  | VecLoad of vec_loadop             (* read memory at address *)
  | VecStore of vec_storeop           (* write memory at address *)
  | VecLoadLane of vec_laneop         (* read single lane at address *)
  | VecStoreLane of vec_laneop        (* write single lane to address *)
  | MemorySize                        (* size of memory *)
  | MemoryGrow                        (* grow memory *)
  | MemoryFill                        (* fill memory range with value *)
  | MemoryCopy                        (* copy memory ranges *)
  | MemoryInit of var                 (* initialize memory range from segment *)
  | DataDrop of var                   (* drop passive data segment *)
  | RefNull of ref_type               (* null reference *)
  | RefFunc of var                    (* function reference *)
  | RefIsNull                         (* null test *)
  | Const of num                      (* constant *)
  | Test of testop                    (* numeric test *)
  | Compare of relop                  (* numeric comparison *)
  | Unary of unop                     (* unary numeric operator *)
  | Binary of binop                   (* binary numeric operator *)
  | Convert of cvtop                  (* conversion *)
  | VecConst of vec                   (* constant *)
  | VecTest of vec_testop             (* vector test *)
  | VecCompare of vec_relop           (* vector comparison *)
  | VecUnary of vec_unop              (* unary vector operator *)
  | VecBinary of vec_binop            (* binary vector operator *)
  | VecConvert of vec_cvtop           (* vector conversion *)
  | VecShift of vec_shiftop           (* vector shifts *)
  | VecBitmask of vec_bitmaskop       (* vector masking *)
  | VecTestBits of vec_vtestop        (* vector bit test *)
  | VecUnaryBits of vec_vunop         (* unary bit vector operator *)
  | VecBinaryBits of vec_vbinop       (* binary bit vector operator *)
  | VecTernaryBits of vec_vternop     (* ternary bit vector operator *)
  | VecSplat of vec_splatop           (* number to vector conversion *)
  | VecExtract of vec_extractop       (* extract lane from vector *)
  | VecReplace of vec_replaceop       (* replace lane in vector *)


(* Locals, globals & Functions *)

type const = instr list Source.phrase

type local = local' Source.phrase
and local' =
{
  ltype : val_type;
}

type global = global' Source.phrase
and global' =
{
  gtype : global_type;
  ginit : const;
}

type func = func' Source.phrase
and func' =
{
  ftype : idx;
  locals : local list;
  body : instr list;
}


(* Tables & Memories *)

type table = table' Source.phrase
and table' =
{
  ttype : table_type;
  tinit : const;
}

type memory = memory' Source.phrase
and memory' =
{
  mtype : memory_type;
}

type tag = tag' Source.phrase
and tag' =
{
  tgtype : idx;
}


type segment_mode = segment_mode' Source.phrase
and segment_mode' =
  | Passive
  | Active of {index : idx; offset : const}
  | Declarative

type elem_segment = elem_segment' Source.phrase
and elem_segment' =
{
  etype : ref_type;
  einit : const list;
  emode : segment_mode;
}

type data_segment = data_segment' Source.phrase
and data_segment' =
{
  dinit : string;
  dmode : segment_mode;
}


(* Modules *)

type type_ = rec_type Source.phrase

type export_desc = export_desc' Source.phrase
and export_desc' =
  | FuncExport of idx
  | TableExport of idx
  | MemoryExport of idx
  | GlobalExport of idx
  | TagExport of idx

type export = export' Source.phrase
and export' =
{
  name : name;
  edesc : export_desc;
}

type import_desc = import_desc' Source.phrase
and import_desc' =
  | FuncImport of idx
  | TableImport of table_type
  | MemoryImport of memory_type
  | GlobalImport of global_type
  | TagImport of idx

type import = import' Source.phrase
and import' =
{
  module_name : name;
  item_name : name;
  idesc : import_desc;
}

type start = start' Source.phrase
and start' =
{
  sfunc : idx;
}

type module_ = module_' Source.phrase
and module_' =
{
  types : type_ list;
  globals : global list;
  tables : table list;
  memories : memory list;
  tags : tag list;
  funcs : func list;
  start : start option;
  elems : elem_segment list;
  datas : data_segment list;
  imports : import list;
  exports : export list;
}


(* Auxiliary functions *)

let empty_module =
{
  types = [];
  globals = [];
  tables = [];
  memories = [];
  tags = [];
  funcs = [];
  start = None;
  elems = [];
  datas = [];
  imports = [];
  exports = [];
}

open Source

let def_types_of (m : module_) : def_type list =
  let rts = List.map Source.it m.it.types in
  List.fold_left (fun dts rt ->
    let x = Lib.List32.length dts in
    dts @ List.map (subst_def_type (subst_of dts)) (roll_def_types x rt)
  ) [] rts

let import_type_of (m : module_) (im : import) : import_type =
  let {idesc; module_name; item_name} = im.it in
  let dts = def_types_of m in
  let et =
    match idesc.it with
    | FuncImport x -> ExternFuncT (Lib.List32.nth dts x.it)
    | TableImport tt -> ExternTableT tt
    | MemoryImport mt -> ExternMemoryT mt
    | GlobalImport gt -> ExternGlobalT gt
    | TagImport x -> ExternTagT (TagT (Lib.List32.nth dts x.it))
  in ImportT (subst_extern_type (subst_of dts) et, module_name, item_name)

let export_type_of (m : module_) (ex : export) : export_type =
  let {edesc; name} = ex.it in
  let dts = def_types_of m in
  let its = List.map (import_type_of m) m.it.imports in
  let ets = List.map extern_type_of_import_type its in
  let et =
    match edesc.it with
    | FuncExport x ->
      let dts = funcs ets @ List.map (fun f ->
        Lib.List32.nth dts f.it.ftype.it) m.it.funcs in
      ExternFuncT (Lib.List32.nth dts x.it)
    | TableExport x ->
      let tts = tables ets @ List.map (fun t -> t.it.ttype) m.it.tables in
      ExternTableT (Lib.List32.nth tts x.it)
    | MemoryExport x ->
      let mts = memories ets @ List.map (fun m -> m.it.mtype) m.it.memories in
      ExternMemoryT (Lib.List32.nth mts x.it)
    | GlobalExport x ->
      let gts = globals ets @ List.map (fun g -> g.it.gtype) m.it.globals in
      ExternGlobalT (Lib.List32.nth gts x.it)
    | TagExport x ->
      let tts = tags ets @ List.map (fun t ->
        TagT (Lib.List32.nth dts t.it.tgtype.it)) m.it.tags in
      ExternTagT (Lib.List32.nth tts x.it)
  in ExportT (subst_extern_type (subst_of dts) et, name)

let module_type_of (m : module_) : module_type =
  let its = List.map (import_type_of m) m.it.imports in
  let ets = List.map (export_type_of m) m.it.exports in
  ModuleT (its, ets)
