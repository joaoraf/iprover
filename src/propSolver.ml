(*----------------------------------------------------------------------(C)-*)
(* Copyright (C) 2006-2010 Konstantin Korovin and The University of Manchester. 
   This file is part of iProver - a theorem prover for first-order logic.

   iProver is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.
   iProver is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  
   See the GNU General Public License for more details.
   You should have received a copy of the GNU General Public License
   along with iProver.  If not, see <http://www.gnu.org/licenses/>.         *)
(*----------------------------------------------------------------------[C]-*)



open Lib
open Statistics

exception Unsatisfiable
exception Create_lit_error

(*
type solver_name   = MiniSat | ZChaff
let current_solver = MiniSat
*)

type solver_out = Sat  | Unsat
(* used in unsta_test:  AUnsat unsat under assumptions*)
type fast_solve = FSat | FUnsat | FUnknown
type lit_val    = True | False | Any
type lit_sign   = Pos  | Neg
type var_id = int

(*
module SatSolver = CMinisat 
*)

module SatSolver = CMinisat 

module SatSolverUC = Minisat 


type lit = SatSolver.literal

type lit_uc = SatSolverUC.literal

type solver = SatSolver.solver

type solver_uc = SatSolverUC.solver

(* to_strings *)

let pp_lit = SatSolver.pp_literal 
    
let lit_to_string solver lit = 
  SatSolver.literal_to_string solver lit

let lit_list_to_string solver lit_list = 
  "[" ^ (Lib.list_to_string (lit_to_string solver) lit_list ",") ^ "]"

let solver_out_to_string = function
  |Sat   -> "Satisfiable"
  |Unsat -> "Unsatisfiable"
  


let lit_val_to_string = function 
  |True  -> "True"
  |False -> "False"
  |Any   -> "Any"

let lit_sign_to_string = function
  |Pos  -> "Positive"
  |Neg  -> "Negative"


let create_solver is_sim = 
  SatSolver.create_solver is_sim

let create_solver_uc is_sim = 
  SatSolverUC.create_solver is_sim

let is_simplification solver = 
  SatSolver.is_simplification solver

let num_of_solver_calls solver = 
  SatSolver.num_of_solver_calls solver

let num_of_fast_solver_calls solver = 
  SatSolver.num_of_fast_solver_calls solver

let num_of_vars solver =
  SatSolver.num_of_vars solver

let num_of_clauses solver =
  SatSolver.num_of_clauses solver

let sign_to_bool = function
  |Pos -> true
  |Neg -> false
	
let bool_to_sign = function
  | true -> Pos
  | false -> Neg
	
let add_var_solver solver var_id =
  SatSolver.add_var solver var_id

let create_lit solver sign var =
  SatSolver.create_lit solver (sign_to_bool sign) var
    
let create_lit_uc solver sign var =
  SatSolverUC.create_lit solver (sign_to_bool sign) var
    
let add_clause solver lits_in =
  try 
    SatSolver.add_clause solver lits_in
  with SatSolver.Unsatisfiable -> 
    (
      (* Format.eprintf "Unsatisfiable with added clause@."; *)
      raise Unsatisfiable
    )
      
let add_clause_with_id solver lits_in =
  try 
    SatSolverUC.add_clause_with_id solver lits_in
  with SatSolverUC.Unsatisfiable -> 
    (
      (* Format.eprintf "Unsatisfiable with added clause in unsat core solver@."; *)
      raise Unsatisfiable
    )
      
let clauses_with_id solver =
  SatSolverUC.clauses_with_id solver


let bool_option_to_val = function
  | Some true -> True 
  | Some false -> False
  | None -> Any


(*  cannot mach a int constant ...
  | l_True    -> True 
  | l_False   -> False
  | l_Undef   -> Any
*)
 
(*	
let lit_val solver lit  = 
  int_to_val (lit_val_minisat solver lit.minisat_val (sign_to_bool lit.sign))
  *)  


let lit_val solver lit  = 
  bool_option_to_val (SatSolver.model_value solver lit)


let solve solver =
  try 
    let start_time = Unix.gettimeofday () in
    let outcome = SatSolver.solve solver in  
    let end_time = Unix.gettimeofday () in
    add_float_stat (end_time -. start_time) prop_solver_time;
    if outcome = true then Sat else Unsat
  with SatSolver.Unsatisfiable -> 
    (
      (* Format.eprintf "Unsatisfiable on solve call@."; *)
      raise Unsatisfiable
    )
      
let solve_uc solver =
  try 
    let start_time = Unix.gettimeofday () in
    let outcome = SatSolverUC.solve solver in  
    let end_time = Unix.gettimeofday () in
    add_float_stat (end_time -. start_time) prop_solver_time;
    if outcome = true then Sat else Unsat
  with SatSolverUC.Unsatisfiable -> 
    (
      (* Format.eprintf "Unsatisfiable on solve call@."; *)
      raise Unsatisfiable
    )
      

let solve_assumptions solver assumptions =
  try 
    let start_time = Unix.gettimeofday () in
    let result = SatSolver.solve_assumptions solver assumptions in
    let end_time = Unix.gettimeofday () in
    add_float_stat (end_time -. start_time) prop_solver_time;
    (match result with 
      | true -> Sat    (* under assumption *) 
      | false -> Unsat)  (* under assumption *) 
  with SatSolver.Unsatisfiable -> 
    (
      (* Format.eprintf "Unsatisfiable without assumptions@."; *)
      raise Unsatisfiable
    )

let solve_assumptions_uc solver assumptions =
  try 
    let start_time = Unix.gettimeofday () in
    let result = SatSolverUC.solve_assumptions solver assumptions in
    let end_time = Unix.gettimeofday () in
    add_float_stat (end_time -. start_time) prop_solver_time;
    (match result with 
      | true -> Sat    (* under assumption *) 
      | false -> Unsat)  (* under assumption *) 
  with SatSolverUC.Unsatisfiable -> 
    (
      (* Format.eprintf "Unsatisfiable without assumptions@."; *)
      raise Unsatisfiable
    )

let fast_solve solver assumptions =
  try 
    let start_time = Unix.gettimeofday () in
    let result = SatSolver.fast_solve solver assumptions in
    let end_time = Unix.gettimeofday () in
    add_float_stat (end_time -. start_time) prop_fast_solver_time;
    (match result with 
      | Some false -> FUnsat    (* under assumption *) 
      | Some true-> FUnknown  (* under assumption *) 
      | None  -> FUnknown)  
  with SatSolver.Unsatisfiable -> 
    (
      (* Format.eprintf "Unsatisfiable without assumptions on fast solving@."; *)
      raise Unsatisfiable
    )

let lit_var solver lit = SatSolver.lit_var solver lit
    
let lit_sign solver lit = SatSolver.lit_sign solver lit

let lit_var_uc solver lit = SatSolverUC.lit_var solver lit
    
let lit_sign_uc solver lit = SatSolverUC.lit_sign solver lit

let get_conflicts solver = SatSolverUC.get_conflicts solver
