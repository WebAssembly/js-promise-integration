(*
 * Simple collection of functions useful for writing test cases.
 *)

open Types
open Value
open Instance


let global (GlobalT (_, t) as gt) =
  let v =
    match t with
    | NumType I32Type -> Num (I32 666l)
    | NumType I64Type -> Num (I64 666L)
    | NumType F32Type -> Num (F32 (F32.of_float 666.6))
    | NumType F64Type -> Num (F64 (F64.of_float 666.6))
    | VecType V128Type -> Vec (V128 (V128.I32x4.of_lanes [666l; 666l; 666l; 666l]))
    | RefType t -> Ref (NullRef t)
  in Global.alloc gt v

let table =
  let tt = TableT ({min = 10l; max = Some 20l}, (Null, FuncHT)) in
  ExternTable (Table.alloc tt (NullRef FuncHT))

let memory =
  let mt = MemoryT {min = 1l; max = Some 2l} in
  ExternMemory (Memory.alloc mt)

let func f ft =
  let dt = DefT (RecT [SubT (Final, [], DefFuncT ft)], 0l) in
  ExternFunc (Func.alloc_host dt (f ft))

let print_value v =
  Printf.printf "%s : %s\n"
    (string_of_value v) (string_of_val_type (type_of_value v))

let print _ vs =
  List.iter print_value vs;
  flush_all ();
  []


let lookup name t =
  match Utf8.encode name, t with
  | "print", _ -> func print (FuncT ([], []))
  | "print_i32", _ -> func print (FuncT ([NumT I32T], []))
  | "print_i64", _ -> func print (FuncT ([NumT I64T], []))
  | "print_f32", _ -> func print (FuncT ([NumT F32T], []))
  | "print_f64", _ -> func print (FuncT ([NumT F64T], []))
  | "print_i32_f32", _ -> func print (FuncT ([NumT I32T; NumT F32T], []))
  | "print_f64_f64", _ -> func print (FuncT ([NumT F64T; NumT F64T], []))
  | "global_i32", _ -> global (GlobalT (Cons, NumT I32T))
  | "global_i64", _ -> global (GlobalT (Cons, NumT I64T))
  | "global_f32", _ -> global (GlobalT (Cons, NumT F32T))
  | "global_f64", _ -> global (GlobalT (Cons, NumT F64T))
  | "table", _ -> table
  | "memory", _ -> memory
  | _ -> raise Not_found
