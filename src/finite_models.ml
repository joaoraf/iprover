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
open Options

type symb   = Symbol.symbol
type symbol = Symbol.symbol
type stype  = Symbol.stype
type term   = Term.term 
type clause = Clause.clause

let symbol_db_ref  = Parser_types.symbol_db_ref
let term_db_ref    = Parser_types.term_db_ref

(* The flattening transformation is based on                          *)
(* Computing Finite Models by Reduction to Function-free clause logic *)
(* by Baumgartner, Fuchs, de Nivelle, Tinelli *)
(* which are extensions of ideas from Paradox *)
(* after flattening each clause is of the form *)
(* ~P_f(y,x)\/~P(x)\/Q(x)\/ x=z *)
(* 1. all P_f are neg., 2. no x \not = y *)


(*-----------Add terms, clauses--------------*)
let add_var_term var = TermDB.add_ref (Term.create_var_term var) term_db_ref
    
let add_fun_term symb args = 
  TermDB.add_ref (Term.create_fun_term symb args) term_db_ref
    
    
let add_neg_lit atom_symb args = 
  add_fun_term Symbol.symb_neg [(add_fun_term atom_symb args)]

(* change later !!!*)

(*
let equality_term t s = 
  let default_type_term = (add_fun_term Symbol.symb_default_type []) in
  let args = [default_type_term;t;s] in
  add_fun_term Symbol.symb_typed_equality  args 
*)

let equality_term eq_type t s = 
  let args = [eq_type;t;s] in
  add_fun_term Symbol.symb_typed_equality  args

let equality_term_type_sym eq_type_sym t s = 
  let eq_type = (add_fun_term eq_type_sym []) in
  equality_term eq_type t s



let dis_equality eq_type t s = 
  add_fun_term Symbol.symb_neg [(equality_term eq_type t s)]

let dis_equality_sym eq_type_sym t s = 
  add_fun_term Symbol.symb_neg [(equality_term_type_sym eq_type_sym t s)]


let add_clause_lits lit_list = 
  Clause.normalise term_db_ref (Clause.create lit_list)  


  (* aux fun *)
let get_val_type sym = Symbol.get_val_type_def sym


(*----------------*)

module SymSet = Set.Make (Symbol)

let flat_sym_set = ref SymSet.empty
let def_sym_set  = ref SymSet.empty
let eq_type_set  = ref SymSet.empty

module SymH = Hashtbl.Make(Symbol)

(* map from flat to original *)
let flat_to_orig = SymH.create 101

let add_flat_to_orig flat orig = 
  if (SymH.mem flat_to_orig flat) 
  then ()
  else 
   SymH.add flat_to_orig flat orig

(*--------------- Flattening Signature ----------------------------*)
(* for each fun. symbol f in signature which also occrs in the input *)
(* we add P_f of arity ar(f) + 1, the first argument of P_f corresponds *)
(* to the value of f *)
(* one should run flat_signature (once) before flattening *)

(* val pred is first arg *)
let get_val_pred_type sym = 
  assert (((Symbol.is_flat sym) && (Symbol.get_arity sym) >0)
	||(Symbol.is_defpred sym));

  let arg_types,_bool_type = Symbol.get_stype_args_val_def  sym in
  let (val_type,_rest) = split_list arg_types in
  val_type

let flat_signature () = 
  let f symb = 
    (
    if (Symbol.is_fun symb) 
	&&
      (Symbol.get_num_input_occur symb) > 0 
	&&
      (not ((Symbol.get_property symb) = Symbol.Type))
    then 
      (
      let new_symb_name = ("$$iProver_Flat_"^(Symbol.get_name symb)) in
      let flat_type = 
	match (Symbol.get_stype_args_val symb) with
	|Def (old_args, old_val) ->
(*            Symbol.create_stype (old_args@[old_val]) Symbol.symb_bool_type*)
	    Symbol.create_stype (old_val::old_args) Symbol.symb_bool_type
	|Undef -> Symbol.create_stype [] Symbol.symb_bool_type
      in
      let flat_symb = 
	Symbol.create_from_str_type_property
	  new_symb_name flat_type  Symbol.Flat in
      let add_flat_symb = SymbolDB.add_ref flat_symb symbol_db_ref in
      flat_sym_set:= SymSet.add add_flat_symb !flat_sym_set;
      add_flat_to_orig add_flat_symb symb;
      Symbol.assign_flattening symb add_flat_symb;
      )
    else ()
    )
  in 
  SymbolDB.iter f !symbol_db_ref



module TermHashKey = 
  struct
    type t    = term
    let equal = (==)
    let hash  = Term.get_fast_key
  end 

(* will have several uses*)
module TermHash = Hashtbl.Make(TermHashKey)

(*-------Definitions for Ground Terms ------------------------------------*)
(* We introduce defintions for each ground non-variable term              *)
(* this helps to shorten the resulting clauses.                           *)
(* We do not introduce explicitly new constants but use the same term for *)
(* its definition, and introduce R_t as the relation corresponding        *) 
(* to this constant                                                       *)
(* term_def_table maps ground terms to symbols which are used to define   *)
(* these terms ex.: for f(g(a))                                           *)
(* the table will contain                                                 *)
(* f(g(a)) -> R_{f(g(a))}; g(a) -> R_{ga}; a -> (Symbol.get_flattening a) *)


let add_term_to_def_test t =
  (Term.is_ground t) && !current_options.sat_gr_def 

let term_def_table = TermHash.create 41 

(* adds definition of a ground term to the table *)
(* fix typed equality! *)
let rec add_term_def_table t = 
  if (TermHash.mem term_def_table t)
  then ()
  else
    match t with 
    |Term.Fun (symb,args,_) ->
	if (Term.is_constant t)
	then 
	  TermHash.add term_def_table t (Symbol.get_flattening symb)
	else
	  (Term.arg_iter add_term_def_table args;
(* replace to a shorter name: based on a counter *)	 
	   let def_symb_name = ("$$iProver_Def_"^(Term.to_string t)) in
	   let def_symb = 
	     Symbol.create_from_str_type_property 
	       def_symb_name 
	       (Symbol.create_stype [(get_val_type symb)] Symbol.symb_bool_type) 
	       Symbol.DefPred in
	   let add_def_symb = SymbolDB.add_ref def_symb symbol_db_ref in 
	   def_sym_set:= SymSet.add add_def_symb !def_sym_set;
	   TermHash.add term_def_table t add_def_symb
	  )
    | Term.Var _ -> failwith "add_term_def_table term should be ground"




(*---------Basic flattening------------------------*)
(* Flattening of a clause is done in two stages:                      *)
(* First, we build a hash table (var_env) mapping non-var term into vars. *)
(* Second, we use var_env  to build flat terms.            *)
(* In "term_flattening_env var_env max_var_ref term"       *)   
(* max_var is max var used                                 *)
(* the input term itself also added to the the var_env     *)
(* if a function term t statisfies add_term_to_def_test    *)
(* we do not need to go                                    *)
(* to subterms  but add 1. a definition t->x into env and  *) 
(* 2. a definition into term_def_table (def. of all subterms of t are also added) *)
(* and later add  \neg R_t(x) to the clause *)

let rec term_flattening_env var_env max_var_ref term = 
  match term with 
  | Term.Var _ -> ()
  | Term.Fun (symb, args, _) -> 
      if (TermHash.mem var_env term) 
      then ()
      else 
	(
	 (if (Symbol.is_fun symb) 
	     && (add_term_to_def_test term)
	 then 
	   ((*out_str ("Adding to add_term_def_table term: "
		     ^(Term.to_string term)^"\n");*)
	    add_term_def_table term)
	 else
	   (
	    let relevant_args = 
	      if (symb == Symbol.symb_typed_equality) 
	      then 
		let (eq_type, t1,t2) = 
		  get_triple_from_list (Term.arg_to_list args) in
(* on the way we also fill set of equality types *)
		let eq_type_sym = Term.get_top_symb eq_type in
		eq_type_set:= SymSet.add eq_type_sym !eq_type_set;
		Term.list_to_arg [t1;t2]
	      else
		args
	    in
	    Term.arg_iter (term_flattening_env var_env max_var_ref) relevant_args)
	 );
	 if (Symbol.is_fun symb)  
	 then
	   (
	    max_var_ref:= Var.get_next_var !max_var_ref;
	   let max_var_term = 
	     TermDB.add_ref (Term.create_var_term !max_var_ref) term_db_ref in
	   TermHash.add var_env term max_var_term
	   )
	 else ()
	)


let flat_term_to_var var_env max_var_ref t = 
  if (Term.is_var t) 
  then t
  else 
    (
     try 
       term_flattening_env var_env max_var_ref t;
       TermHash.find var_env t
     with Not_found -> failwith "flat_term_to_var: Not_found"
    )
	

let order_term_var tv1 tv2 = 
  if (Var.compare (Term.get_var tv1) (Term.get_var tv2)) > 0 
  then (tv1,tv2) 
  else (tv2,tv1)


(* We obtain flat def. of terms in var_env and   *)
(* a normalised subst. corresponding to x \not = y *)
(* subst is kept confluent *)
(* later this substitution will be applied to all variables*)
let flat_lit_env var_env max_var_ref neg_var_subst_ref lit = 
  if (Term.is_neg_lit lit)
  then 
    begin
      let atom = Term.get_atom lit in 
      match atom with 
      | Term.Fun (symb, args, _) -> 
	  if (symb == Symbol.symb_typed_equality) 
	  then 
	  (* flat neg eq: t\=s 1. t->x s->y added to var_env,   *)
          (* then x\not y is normalised and added to subst.     *)  

(*	    let (t1,t2) = get_pair_from_list (Term.arg_to_list args) in*)
	    let (_eq_type, t1, t2) = get_triple_from_list (Term.arg_to_list args) in
(*	    let rec fl t1 t2 = *)
	    if t1==t2 then ()
	    else	      
	      let var_t1 = flat_term_to_var var_env  max_var_ref t1 in
	      let var_t2 = flat_term_to_var var_env  max_var_ref t2 in		   
	      let norm_t1 = 
		Subst.find_normalised !neg_var_subst_ref var_t1 in 
	      let norm_t2 = 
		Subst.find_normalised !neg_var_subst_ref var_t2 in
	      if  norm_t1==norm_t2 
	      then ()
	      else 
		begin
		  let (big_t, small_t) = order_term_var norm_t1 norm_t2 in
		  neg_var_subst_ref:= 
		    Subst.add (Term.get_var big_t) small_t !neg_var_subst_ref
		end		    
		  (* atom is not equality *)
	  else
	    term_flattening_env var_env max_var_ref atom

      | Term.Var _ -> failwith "flat_lit_env: atom cannot be a var"
end

(* positive lit*)
  else 
    term_flattening_env var_env max_var_ref lit
	  

let rec get_max_var_term current_max_var_ref term =  
  match term with 
  |Term.Fun (_, args,_) ->  
      Term.arg_iter (get_max_var_term current_max_var_ref) args
  |Term.Var (v,_) -> 
      if (Var.compare v !current_max_var_ref) > 0
      then 
	(current_max_var_ref := v)
      else ()
	  
let get_max_var clause = 
  let var_ref  = ref (Var.get_first_var ()) in
  Clause.iter (get_max_var_term var_ref) clause;
  !var_ref


(*---------------------------------*)
let flat_clause clause = 
  let var_env = TermHash.create 19 in
  let max_var_ref = ref (get_max_var clause) in
  let neg_var_subst_ref = ref (Subst.create ()) in
  Clause.iter (flat_lit_env var_env max_var_ref neg_var_subst_ref) clause;
(* now we have the map of non-var terms  to corresponding vars in var_env *)
(* get var_term corresponding to the term in var_env *)
  let term_to_var_term term =
    try  
      (Subst.find_normalised  !neg_var_subst_ref 
	 (TermHash.find var_env term))
    with Not_found ->
      if (Term.is_var term)
      then Subst.find_normalised  !neg_var_subst_ref term 
      else
	failwith ("term_to_var_term: Not_found term: "
				^(Term.to_string term))
  in
(* first we flatten top of predicates and pos. eq. *)
(* (neq eq translates to x\=y and was added to subst.), *)
(* then we add all flattenings of terms in var_env *)
  let flat_lit rest lit = 
    let atom = Term.get_atom lit in 
    match atom with 
    | Term.Fun (symb, args, _) -> 
	if (symb == Symbol.symb_typed_equality) 
	then
	  if (Term.is_neg_lit lit) 
	  then
(* all neg eq are falttend to x\not y which are added to neg_var_subst_ref *)
(* and will be added to the rest later *)
	    rest 
	  else
	    (*positive eq, terms replaced by definitions *)
	   (* let (t1,t2) = get_pair_from_list (Term.arg_to_list args) in*)
	    let (eq_type,t1,t2) = get_triple_from_list (Term.arg_to_list args) in
	    (* replace *)
	    (equality_term eq_type (term_to_var_term t1) (term_to_var_term t2))::rest
	else 
(* non equlaity literal *)
	  let new_atom = 
	    let new_args = Term.arg_to_list (Term.arg_map term_to_var_term args) in
	    add_fun_term symb new_args 
	  in   
	  let new_lit = 
	    if (Term.is_neg_lit lit) 
	    then 
	      add_fun_term Symbol.symb_neg [new_atom] 
	    else 
	      new_atom 
	  in
	  new_lit::rest	  
    | Term.Var _ -> failwith "flat_lit: atom cannot be var"
  in
  let flat_part =  Clause.fold flat_lit [] clause in
  let get_env_part term var_term rest = 
    let new_var_term = 	    
      (Subst.find_normalised !neg_var_subst_ref var_term) in	      
    match term with 
    | Term.Fun (symb, args, _) -> 
	let new_atom =   
	  if (add_term_to_def_test term)
	  then 
	    (try 	 
	      let new_symb = (TermHash.find term_def_table term) in
	      add_fun_term new_symb [new_var_term] 	      
	    with Not_found -> 
	      failwith "get_env_part: ground term shoud be in term_def_table "
	    )
	  else
	    (let new_symb = Symbol.get_flattening symb in	  	
(* the value of the function is the first argument of the relation*)	
	    let new_args = new_var_term::
	      (Term.arg_to_list (Term.arg_map term_to_var_term args)) 
	    in
	    add_fun_term new_symb new_args 
	    )
	in 
	let new_lit = add_fun_term Symbol.symb_neg [new_atom] in
	new_lit::rest
    | Term.Var _ -> failwith "get_env_part should not be var term"
  in
  let env_part = TermHash.fold get_env_part var_env [] in
  add_clause_lits (env_part@flat_part)
    
(*----------------------------------------------------------------*)
(* Gets definitions from the term_def_table                       *)
(* Ex: we need to get f(t1,..,tn) = c_f(t1,..,tn)                 *)
(* which can be defined as                                        *)
(* \neg P_t1(X1)\/..\/ \neg P_tn(Xn) \/ \neg P_f(t1,...,tn)(Z) \/ *)
(* \/ \neg P_f(Val,X1,..,Xn)\/ Z=Val                              *)
(* constants are not redefined *)

(*----------------definitions are wrong and do not work!---------------------*)
(*--------------------fix later --------------------*)
let _ = out_str ("\n\n!Fix Definitions in finite_models!\n\n")

let get_definitions () =
  let f t def_symb rest = 
    match t with 
    |Term.Fun (symb,args,_) ->
	if (Term.is_constant t)
	then 
(* no def. for constants needed *)
	  rest
	else
	  (
(*  [\neg P_t1(X1);.. \neg P_tn(Xn)] *)
	   let current_var = ref (Var.get_first_var ()) in
	   let arg_vars = ref [] in
	   let f arg_lits_rest arg_term = 
	     try
	       let new_symb = TermHash.find term_def_table arg_term in
	       let new_var_term = add_var_term !current_var in
	       arg_vars:= new_var_term::!arg_vars;
	       let new_lit =  add_neg_lit new_symb [new_var_term] in
	       current_var:= Var.get_next_var !current_var;  
	       new_lit::arg_lits_rest
	     with 
	       Not_found -> 
		 failwith "get_definitions: term should be in term_def_table "
	   in
	   let arg_lits = Term.arg_fold_left f [] args in
	   arg_vars := List.rev !arg_vars;

(* \neg P_f(t1,...,tn)(Z) *)
	   current_var:= Var.get_next_var !current_var;
	   let p_f_t_lit_var = add_var_term !current_var in 	   
	   let p_f_t_lit = add_neg_lit def_symb [p_f_t_lit_var] in 
	  
(*\neg P_f(Val,X1,..,Xn) *)	   
	   current_var:= Var.get_next_var !current_var;
	   let val_var = add_var_term  !current_var in
	   let p_f_symb = Symbol.get_flattening symb in
	   let p_f_lit = add_neg_lit p_f_symb (val_var::(!arg_vars)) in
(*Z=Val*)  
	   let z_val_lit = equality_term_type_sym 
	       (get_val_type symb) p_f_t_lit_var val_var in
	   let new_clause = 
	     add_clause_lits (z_val_lit::p_f_lit::p_f_t_lit::arg_lits) in
	   new_clause::rest
	  )
	  	  
    |Term.Var _ -> failwith "get_definitions: term should be ground"	  
  in
  TermHash.fold f term_def_table [] 

(* definitions should be fixed!!! *)

let flat_clause_list clause_list = 
 let flat_clauses =  List.map flat_clause clause_list in
 let definitions  = get_definitions () in 
 definitions@flat_clauses



(*---------------Axioms-------------------------*)

(* bound_pred is added to clauses which are active at the current domain bound i *)
let create_bound_pred i = 
  let bound_symb_name = ("$$iProver_Bound_Pred_"^(string_of_int i)) in
  let bound_symb = 
    Symbol.create_from_str_type_property 
      bound_symb_name (Symbol.create_stype [] Symbol.symb_bool_type) 
      Symbol.DomainPred in
  let add_bound_symb = SymbolDB.add_ref bound_symb symbol_db_ref in
  add_fun_term add_bound_symb []
 

(*-----------------------*)
type domain = 
    {
     dom_type : symbol;
     mutable dom_elements : term list;
(* all flat and defpred symbols with value type of domain_type *)
     mutable dom_flat_preds : symbol list; 
(*     mutable dom_def_preds : symbol list; *)
   }

let create_domain dom_type = 
  {
   dom_type = dom_type;
   dom_elements =[];
   dom_flat_preds = [];
 }


(*
module DKey = 
  struct 
    type t = domain
    let equal d1 d2 = Symbol.equal d1.dom_type d2.dom_type
    let hash d = Symbol.hash d.dom_type
  end
*)

(* TDomainH hash table mapping domain_type -> domain *)
module TDomainH = Hashtbl.Make(Symbol)

let domain_table = TDomainH.create 101

(*------domains should be initialised before use!-----*)
let init_domains () = 
  let f flat_pred = 
     let val_type = get_val_pred_type flat_pred in
     try 
(*
       out_str ("dom pred "^(Symbol.to_string flat_pred)
		^" domain type: "^(Symbol.to_string val_type)^"\n");
*)
       let dom = TDomainH.find domain_table val_type in 
      dom.dom_flat_preds <- flat_pred::(dom.dom_flat_preds)
    with 
      Not_found -> 
	(
	 let new_dom = create_domain val_type in 
	 new_dom.dom_flat_preds <- [flat_pred];
	 TDomainH.add domain_table val_type new_dom
	)
  in
  SymSet.iter f !flat_sym_set


let add_domain_constant dom i = 
  let dom_symb_name = 
    ("$$iProver_Domain_"^(Symbol.to_string dom.dom_type)^"_"^(string_of_int i)) in

  let dom_symb = 
    Symbol.create_from_str_type_property 
(*      dom_symb_name (Symbol.create_stype [] Symbol.symb_default_type) Symbol.DomainConstant in*)
      dom_symb_name (Symbol.create_stype [] dom.dom_type) Symbol.DomainConstant in
  let add_dom_symb = SymbolDB.add_ref dom_symb symbol_db_ref in
  let dom_i_el =  add_fun_term add_dom_symb [] in
  dom.dom_elements <- dom_i_el::(dom.dom_elements)
(*
  try 
    let dom = TDomainH.find domain_table dom_type in
    dom.dom_elements <- dom_i_el::(dom.dom_elements)
  with 
    Not_found -> failwith "add_domain_constant: dom_type should be in domain_table"
 *)


let add_domain_constant_all_dom i = 
(*  out_str ("adding const"^(string_of_int i)^"\n");*)
  TDomainH.iter 
    (fun _dom_type dom -> add_domain_constant dom i) domain_table

  
(*
let add_domain_constants domain first last = 

  let dom_const_list_ref = ref [] in
  for i=first to last 
  do
    let add_dom_const = add_domain_constant dom_type i in
    dom_const_list_ref:=add_dom_const::!dom_const_list_ref
  done;
  !dom_const_list_ref
*)  

(*--------- disequality axioms -----------*)
let dis_eq_axioms eq_type t term_list = 
  let f rest_f s = 
    if not (s==t) 
    then 	
      (add_clause_lits [(dis_equality_sym eq_type t s)])::rest_f
    else 
      rest_f
  in 
  List.fold_left f [] term_list 

(* for all pairs t s in term_list adding t!=s *)
(* we need to add both t!=s and s!=t since we don not add symmetry axioms*)
let dis_eq_axioms_list eq_type term_list = 
  let f rest t =     
    (dis_eq_axioms eq_type t term_list)@rest
  in
  List.fold_left f [] term_list 


let dis_eq_axioms_dom dom = 
(* we do not need to add disequality axioms for non-equality types *)
  if (SymSet.mem dom.dom_type !eq_type_set) 
  then
    dis_eq_axioms_list dom.dom_type dom.dom_elements
  else
    []

let dis_eq_axioms_all_dom () =  
  TDomainH.fold 
    (fun _dom_type dom rest_ax -> ((dis_eq_axioms_dom dom)@rest_ax)) domain_table []

(*----------------------------*)
(* version with symmetry ax in place of explicit pairs t!=s  and s!=t *)

let dis_eq_axioms_sym_list eq_type term_list = 
 let rec dis_eq_axioms_sym_list' ax_list term_list_rest = 
   match term_list_rest with 
   |h::tl -> 
       let new_ax = dis_eq_axioms eq_type h tl in
       let current_ax= new_ax@ax_list in
       dis_eq_axioms_sym_list' current_ax tl
   |[] -> ax_list
 in
 dis_eq_axioms_sym_list' [] term_list

let dis_eq_axioms_dom_sym dom = 
(*  out_str ("domain type"^(Symbol.to_string dom.dom_type)^" domain terms: "^(Term.term_list_to_string dom.dom_elements)^"\n");*)

(* we do not need to add disequality axioms for non-equality types *)
  if (SymSet.mem dom.dom_type !eq_type_set) 
  then
    begin
      let sym_axiom = Eq_axioms.typed_symmetry_axiom_sym dom.dom_type in
      let dis_ax = (dis_eq_axioms_sym_list dom.dom_type dom.dom_elements) in
(* for the dome size 1 we do not need to add sym_axiom *)
      if dis_ax = [] 
      then []
      else sym_axiom::dis_ax
    end
  else
    []

let dis_eq_axioms_all_dom_sym () =  
  TDomainH.fold 
    (fun _dom_type dom rest_ax -> ((dis_eq_axioms_dom_sym dom)@rest_ax)) domain_table []

(*-----------------*)

(* symbol is a flat symbol, dom_pred is the predicate added to the clause *)
(*to encode crurrent domain *)
(* ex if symb is R and domain terms [1;..;n] then *)
(* the result is dom_pred \/ R(1,x_1,x_2)\/R(2,x_1,x_2)\/...\/R(n,x_1,x_2)*)

 let axiom_dom_pred_symb bound_pred symb dom_elements =   
    let rec get_var_args rest current_var i = 
      if i = 0 then List.rev rest
      else 
	get_var_args 
	  ((add_var_term current_var)::rest) (Var.get_next_var current_var) (i-1)
    in     
    let var_args = 
      get_var_args [] (Var.get_first_var ()) ((Symbol.get_arity symb)-1) 
    in 
    let f rest dom_el = 
      (add_fun_term symb (dom_el::var_args))::rest
    in
    let new_cl = 
      (add_clause_lits (bound_pred::(List.fold_left f [] dom_elements))) in
    new_cl

let domain_pred_axioms bound_pred dom =
   List.fold_left (fun rest symb  -> 
    ((axiom_dom_pred_symb bound_pred symb dom.dom_elements)::rest)) 
    []
    dom.dom_flat_preds




(*------------ All domain axioms without symmetry breaking --------------------*)

let domain_pred_axioms_all_dom bound_pred = 
  TDomainH.fold 
    (fun _dom_type dom rest_ax -> 
      ((domain_pred_axioms bound_pred dom)@rest_ax)) domain_table []



(*----optimized version with restricted domain for constants----*)
(* triangular symmetry breaking: first order the constants *)
(* by the number of occurrences then  *)
(* P_c1(1)                            *)
(* P_c2(1)\/P_c2(2)                   *)
(*....................................*)
(* P_ck(1)\/......\/P_ck(k)           *)
(* P_c(k+1)(1)\/..\/P_c(k+1)(k)       *)
(*....................................*)
(* P_cn(1)\/......\/P_cn(k)           *)
(*where k is the domain size = numb dom terms *)

let domain_axioms_triangular_const_list bound_pred dom_elements ordered_flat_consts =
  let rec i_const_lits rest_dom_elements i symb = 
    match rest_dom_elements with 
    | [] -> []
    | h::tl ->
	if (i =0) then []
	else 
	  ((add_fun_term symb [h])::(i_const_lits tl (i-1) symb))
  in  
  let get_axioms_const (rest,i) symb = 
    let new_clause = 
      add_clause_lits (bound_pred::(i_const_lits dom_elements i symb)) in
    ((new_clause::rest),i+1)
  in
  let (axioms_const,_) = 
    List.fold_left get_axioms_const ([],1) ordered_flat_consts in
  axioms_const

(*-------------------------------*)
let domain_axioms_triangular bound_pred = 
  let num_of_occurences flat_sym = 
    try 
      let orig_symb = SymH.find flat_to_orig flat_sym in
      Symbol.get_num_input_occur orig_symb
    with Not_found -> failwith "domain_axioms_triangular_const: should not happen"
  in
  let cmp_occur s1 s2 = 
    -(compare (num_of_occurences s1) (num_of_occurences s2)) in 

  let order_flat_consts flat_consts = List.sort cmp_occur flat_consts in
  
(* returns (pred_const, other_pred) *)
  let split pred_list = 
    List.fold_left 
      (fun (pred_cont_rest,other_pred_rest) pred -> 
	(if  ((Symbol.get_arity pred) = 1)
	then
	  ((pred::pred_cont_rest),other_pred_rest)
	else
	  (pred_cont_rest,(pred::other_pred_rest))
	)
      )
      ([],[])
      pred_list
  in
  let dom_fun dom = 
    let (flat_consts, other_preds) = split dom.dom_flat_preds in
    let ordered_flat_consts = order_flat_consts flat_consts in
    let flat_consts_ax =  
      domain_axioms_triangular_const_list 
	bound_pred dom.dom_elements ordered_flat_consts 
    in 
    let other_preds_ax = 
      List.fold_left (fun rest symb  -> 
	((axiom_dom_pred_symb bound_pred symb dom.dom_elements)::rest)) 
	[]
	other_preds
    in
    flat_consts_ax@other_preds_ax
  in   
  TDomainH.fold 
    (fun _dom_type dom rest_ax -> 
      ((dom_fun dom)@rest_ax)) domain_table []


(*
 (pred_const, other_pred) = 
    (Symbol.get_arity s) >1) split flat_pred_list 
  let dom_fun dom = 
    flat_to_orig
*)

(*


let domain_axioms_triangular_const dom_pred dom_terms const_list = 
  let cmp c1 c2 = 
    -(compare (Symbol.get_num_input_occur c1) (Symbol.get_num_input_occur c2)) in 
  let ordered_const_list = List.sort cmp const_list in
  let oredered_flat_const_list = List.map Symbol.get_flattening ordered_const_list
  in
  let rec i_const_lits rest_dom_terms i symb = 
    match rest_dom_terms with 
    | [] -> []
    | h::tl ->
	if (i =0) then []
	else 
	  ((add_fun_term symb [h])::(i_const_lits tl (i-1) symb))
  in  
  let get_axioms_const (rest,i) symb = 
    let new_clause = 
      add_clause_lits (dom_pred::(i_const_lits dom_terms i symb)) in
    ((new_clause::rest),i+1)
  in
  let (axioms_const,_) = 
    List.fold_left get_axioms_const ([],1) oredered_flat_const_list in
  axioms_const



(* auxilary returns (const_list,non_const_flat_pred) in the signature*)
(* const_list is the original (not flat) and non_const_flat_pred are *)
(* non constant flat predicates *)
(* definition symbols from term_def_table are treated as other*)

let split_input_constants_other () =
  let split_constants_other' s (const_rest,flat_pred_rest)  = 
    if (Symbol.is_constant s) && (Symbol.get_num_input_occur s) >0 
    then (
(*      out_str ((Symbol.to_string s)
	       ^" num_occ: "^(string_of_int (Symbol.get_num_input_occur s))^"\n"); *)
      ((s::const_rest),flat_pred_rest))
    else 
      if (((Symbol.is_flat s) && (Symbol.get_arity s) >1)
	||(Symbol.is_defpred s))
      then 	
	(const_rest,(s::flat_pred_rest))	
      else	
	(const_rest,flat_pred_rest)
  in
  SymbolDB.fold split_constants_other' !symbol_db_ref ([],[]) 
  

*)

(*----Triangular axioms for constants and plus axioms for the rest-----------*)

(* Commented for the moment


let domain_axioms_triangular dom_pred dom_terms = 
  let (const_list,non_const_flat_pred) = split_input_constants_other () in
  (* axioms for constants *)
  let axioms_const = domain_axioms_triangular_const dom_pred dom_terms const_list in
(* axioms for the rest: non constants *)
  let axioms_flat_rest = 
    domain_axioms_symb_list dom_pred dom_terms non_const_flat_pred in
  axioms_const@axioms_flat_rest


(*-----------------------------------------*)
(*------ Unit version for constants -------*)
(*---In some cases it is enough to have unit axioms for constants:---*)
(* P_c1(1), P_c2(2),..., P_ck(k) *)
(* where we assume that number domain terms >= number of constants *)
(* This is true for problems without equality *)

let domain_axioms_unit_const dom_pred dom_terms const_list = 
(* we do not need to sort constants here but just for fun *)
 let cmp c1 c2 = 
    -(compare (Symbol.get_num_input_occur c1) (Symbol.get_num_input_occur c2)) in 
  let ordered_const_list = List.sort cmp const_list in
  let oredered_flat_const_list = List.map Symbol.get_flattening ordered_const_list
  in 
(* 
   out_str ("Flat Constants:\n "^(list_to_string Symbol.to_string oredered_flat_const_list "\n")^"\n");
   out_str ("Domain Terms:\n "^(list_to_string Term.to_string dom_terms "\n")^"\n");
*)
  let rec f const_list_dom_terms_rest =
    match const_list_dom_terms_rest with 
    | (p_c::c_tl,t::t_tl) ->  
	(add_clause_lits [(add_fun_term p_c [t])])::(f (c_tl,t_tl))
    | ([],_) -> []
    | (_,[]) -> 
	failwith 
	  "domain_axioms_unit_const: domain should be greater than the number of constants"
  in
  f (oredered_flat_const_list,dom_terms)
  
let domain_axioms_unit dom_pred dom_terms = 
  let (const_list,non_const_flat_pred) = split_input_constants_other () in
  (* axioms for constants *)
  let axioms_const = domain_axioms_unit_const dom_pred dom_terms const_list in
(* axioms for the rest: non constants *)
  let axioms_flat_rest = 
    domain_axioms_symb_list dom_pred dom_terms non_const_flat_pred in
  axioms_const@axioms_flat_rest
		  
*)

let init_finite_models () = 
  flat_signature ();  
  init_domains ()
