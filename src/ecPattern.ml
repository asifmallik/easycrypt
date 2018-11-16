open EcUtils
open EcFol
open EcTypes
open EcPath
open EcMemory
open EcIdent
open EcModules

module Name = EcIdent

module MName = Mid

(* -------------------------------------------------------------------------- *)

type meta_name = Name.t

type axiom =
  | Axiom_Form     of form
  | Axiom_Memory   of memory
  | Axiom_MemEnv   of memenv
  | Axiom_Prog_Var of prog_var
  | Axiom_Op       of path * ty list
  | Axiom_Module   of mpath_top
  | Axiom_Mpath    of mpath
  | Axiom_Instr    of instr
  | Axiom_Stmt     of stmt
  | Axiom_Lvalue   of lvalue
  | Axiom_Xpath    of xpath
  | Axiom_Hoarecmp of hoarecmp
  | Axiom_Local    of ident * ty

type fun_symbol =
  (* from type form *)
  | Sym_Form_If
  | Sym_Form_App          of ty
  | Sym_Form_Tuple
  | Sym_Form_Proj         of int
  | Sym_Form_Match        of ty
  | Sym_Form_Quant        of quantif * bindings
  | Sym_Form_Let          of lpattern
  | Sym_Form_Pvar         of ty
  | Sym_Form_Prog_var     of pvar_kind
  | Sym_Form_Glob
  | Sym_Form_Hoare_F
  | Sym_Form_Hoare_S
  | Sym_Form_bd_Hoare_F
  | Sym_Form_bd_Hoare_S
  | Sym_Form_Equiv_F
  | Sym_Form_Equiv_S
  | Sym_Form_Eager_F
  | Sym_Form_Pr
  (* form type stmt*)
  | Sym_Stmt_Seq
  (* from type instr *)
  | Sym_Instr_Assign
  | Sym_Instr_Sample
  | Sym_Instr_Call
  | Sym_Instr_Call_Lv
  | Sym_Instr_If
  | Sym_Instr_While
  | Sym_Instr_Assert
  (* from type xpath *)
  | Sym_Xpath
  (* from type mpath *)
  | Sym_Mpath
  (* generalized *)
  | Sym_App
  | Sym_Quant             of quantif * ((ident * (gty option)) list)

(* invariant of pattern : if the form is not Pat_Axiom, then there is
     at least one of the first set of patterns *)
type pattern =
  | Pat_Anything
  | Pat_Meta_Name  of pattern * meta_name
  | Pat_Sub        of pattern
  | Pat_Or         of pattern list
  | Pat_Instance   of pattern option * meta_name * path * pattern list
  | Pat_Red_Strat  of pattern * reduction_strategy

  | Pat_Fun_Symbol of fun_symbol * pattern list
  | Pat_Axiom      of axiom
  | Pat_Type       of pattern * gty

and reduction_strategy = pattern -> axiom -> (pattern * axiom) option


(* This is for EcTransMatching ---------------------------------------- *)
let default_start_name = "$start"
let default_end_name = "$end"
let default_name = "$default"


(* -------------------------------------------------------------------------- *)
let olist_all (f : 'a -> 'b option) (l : 'a list) : 'b list option =
  let rec aux accb = function
    | []     -> Some (List.rev accb)
    | a :: r -> match f a with
                | None -> None
                | Some b -> aux (b::accb) r
  in aux [] l

(* -------------------------------------------------------------------------- *)
let rec expr_of_form (f : form) : expr option = match f.f_node with
  | Fquant (q,b,f1)    ->
     let eq = match q with
       | Llambda -> `ELambda
       | Lforall -> `EForall
       | Lexists -> `EExists in
     let b = try Some(List.map (snd_map EcFol.gty_as_ty) b) with
             | _ -> None in
     odfl None (omap (fun b -> omap (EcTypes.e_quantif eq b)
                                 (expr_of_form f1)) b)
  | Fif (f1,f2,f3)     -> begin
      match expr_of_form f1 with
      | None -> None
      | Some e1 ->
      match expr_of_form f2 with
      | None -> None
      | Some e2 ->
      match expr_of_form f3 with
      | None -> None
      | Some e3 -> Some (EcTypes.e_if e1 e2 e3)
    end
  | Fmatch (f1,lf,ty) -> begin
      match expr_of_form f1 with
      | None -> None
      | Some e1 -> omap (fun l -> EcTypes.e_match e1 l ty)
                     (olist_all expr_of_form lf)
    end
  | Flet (lp,f1,f2)    ->
     odfl None
       (omap (fun e1 ->
            omap (fun e2 -> EcTypes.e_let lp e1 e2)
              (expr_of_form f2))
          (expr_of_form f1))
  | Fint i             -> Some (EcTypes.e_int i)
  | Flocal id          -> Some (EcTypes.e_local id f.f_ty)
  | Fpvar (pv,_)       -> Some (EcTypes.e_var pv f.f_ty)
  | Fop (op,lty)       -> Some (EcTypes.e_op op lty f.f_ty)
  | Fapp (f1,args)     ->
     odfl None
       (omap (fun e1 ->
            omap (fun l -> EcTypes.e_app e1 l f.f_ty)
              (olist_all expr_of_form args))
          (expr_of_form f1))
  | Ftuple t           ->
     omap (fun l -> EcTypes.e_tuple l) (olist_all expr_of_form t)
  | Fproj (f1,i)       ->
     omap (fun e -> EcTypes.e_proj e i f.f_ty) (expr_of_form f1)
  | _                  -> None

(* -------------------------------------------------------------------------- *)

type map = pattern MName.t


(* -------------------------------------------------------------------------- *)
let pat_axiom x = Pat_Axiom x

let pat_form f      = pat_axiom (Axiom_Form f)
let pat_mpath m     = pat_axiom (Axiom_Mpath m)
let pat_mpath_top m = pat_axiom (Axiom_Module m)
let pat_xpath x     = pat_axiom (Axiom_Xpath x)
let pat_op op lty   = pat_axiom (Axiom_Op (op,lty))
let pat_lvalue lv   = pat_axiom (Axiom_Lvalue lv)
let pat_instr i     = pat_axiom (Axiom_Instr i)
let pat_stmt s      = pat_axiom (Axiom_Stmt s)
let pat_local id ty = pat_axiom (Axiom_Local (id,ty))

(* -------------------------------------------------------------------------- *)

let pat_add_fv map (n : ident) =
  match Mid.find_opt n map with
  | None -> Mid.add n 1 map
  | Some i -> Mid.add n (i+1) map

let pat_fv_union m1 m2 =
  Mid.fold_left (fun m n _ -> pat_add_fv m n) m1 m2

let pat_fv p =
  let rec aux (map : int Mid.t) = function
    | Pat_Anything -> map
    | Pat_Meta_Name (p,n) ->
       aux (pat_add_fv map n) p
    | Pat_Sub p -> aux map p
    | Pat_Or lp -> List.fold_left aux map lp
    | Pat_Instance _ -> assert false
    | Pat_Red_Strat (p,_) -> aux map p
    | Pat_Type (p,_) -> aux map p
    | Pat_Fun_Symbol (_,lp) -> List.fold_left aux map lp
    | Pat_Axiom a ->
       match a with
       | Axiom_Form f -> pat_fv_union f.f_fv map
       | Axiom_Memory m -> pat_add_fv map m
       | Axiom_Instr i -> pat_fv_union map i.i_fv
       | Axiom_Stmt s -> pat_fv_union map s.s_fv
       | _ -> map
  in aux Mid.empty p

(* -------------------------------------------------------------------------- *)
let p_equal : pattern -> pattern -> bool = (==)

(* -------------------------------------------------------------------------- *)
let p_mpath (p : pattern) (args : pattern list) =
  let rec oget_mpaths acc = function
    | [] -> Some (List.rev acc)
    | (Pat_Axiom(Axiom_Mpath m))::r ->
       oget_mpaths (m::acc) r
    | (Pat_Axiom(Axiom_Module mt))::r ->
       oget_mpaths ((mpath mt [])::acc) r
    | _ -> None in
  let oget_mpaths l = oget_mpaths [] l in
  let oget_mpath =
    match p with
    | Pat_Axiom(Axiom_Module mt) -> Some (mpath mt [])
    | Pat_Axiom(Axiom_Mpath m)   -> Some m
    | _ -> None in
  match oget_mpath, oget_mpaths args with
  | Some m, Some args ->
     Pat_Axiom(Axiom_Mpath (mpath m.m_top (m.m_args @ args)))
  | _,_ -> Pat_Fun_Symbol(Sym_Mpath,p::args)

let p_xpath (p : pattern) (f : pattern) =
  match p,f with
  | Pat_Axiom(Axiom_Mpath m),Pat_Axiom(Axiom_Op (op,[])) ->
     Pat_Axiom(Axiom_Xpath (EcPath.xpath m op))
  | _ -> Pat_Fun_Symbol(Sym_Xpath,[p;f])

let p_prog_var (p : pattern) (k : pvar_kind) =
  match p with
  | Pat_Axiom(Axiom_Xpath x) -> Pat_Axiom(Axiom_Prog_Var (pv x k))
  | _ -> Pat_Fun_Symbol(Sym_Form_Prog_var k,[p])

let p_lvalue_var (p : pattern) (ty : ty) =
  match p with
  | Pat_Axiom(Axiom_Prog_Var pv) ->
     Pat_Axiom(Axiom_Lvalue(LvVar(pv,ty)))
  | p -> Pat_Type(p,GTty ty)

let p_lvalue_tuple (p : pattern list) =
  let rec oget_pv acc = function
    | [] -> Some (List.rev acc)
    | a :: r ->
       match a with
       | Pat_Type(Pat_Axiom(Axiom_Prog_Var pv),GTty ty)
         | Pat_Axiom(Axiom_Lvalue(LvVar (pv,ty))) ->
          oget_pv ((pv,ty)::acc) r
       | _ -> None
  in match oget_pv [] p with
     | None -> Pat_Fun_Symbol(Sym_Form_Tuple,p)
     | Some l -> Pat_Axiom(Axiom_Lvalue(LvTuple l))



let p_if (p1 : pattern) (p2 : pattern) (p3 : pattern) =
  Pat_Fun_Symbol(Sym_Form_If,[p1;p2;p3])

let p_proj (p1 : pattern) (i : int) (ty : ty) =
  Pat_Type(Pat_Fun_Symbol(Sym_Form_Proj i,[p1]),GTty ty)

let p_let (l : lpattern) (p1 : pattern) (p2 : pattern) =
  match p1,p2 with
  | Pat_Axiom(Axiom_Form f1),Pat_Axiom(Axiom_Form f2) ->
     pat_form (EcFol.f_let l f1 f2)
  | _ -> Pat_Fun_Symbol(Sym_Form_Let l,[p1;p2])

let p_app (p : pattern) (args : pattern list) (ty : ty option) =
  match args,ty with
  | [],_ -> p
  | _, None ->
     Pat_Fun_Symbol(Sym_App,p::args)
  | _,Some ty -> Pat_Fun_Symbol(Sym_Form_App ty,p::args)

let p_f_quant q bs p =
  match bs with
  | [] -> p
  | _  -> Pat_Fun_Symbol(Sym_Form_Quant (q,bs),[p])

let p_quant q bs p =
  match bs with
  | [] -> p
  | _  -> Pat_Fun_Symbol(Sym_Quant (q,bs),[p])

let p_f_forall b p = p_f_quant Llambda b p

let p_f_exists b p = p_f_quant Lexists b p

let p_pvar (x : prog_var) (ty : ty) (m : EcMemory.memory) =
  pat_form(EcFol.f_pvar x ty m)


let p_assign (plv : pattern) (pe : pattern) = match plv, pe with
  | Pat_Axiom(Axiom_Lvalue lv),Pat_Axiom(Axiom_Form f) -> begin
      match expr_of_form f with
      | None ->
         Pat_Fun_Symbol(Sym_Instr_Assign,[plv;pe])
      | Some e -> Pat_Axiom(Axiom_Instr(i_asgn (lv,e)))
    end
  | _ -> Pat_Fun_Symbol(Sym_Instr_Assign,[plv;pe])

let p_sample (plv : pattern) (pe : pattern) = match plv, pe with
  | Pat_Axiom(Axiom_Lvalue lv),Pat_Axiom(Axiom_Form f) -> begin
      match expr_of_form f with
      | None ->
         Pat_Fun_Symbol(Sym_Instr_Sample,[plv;pe])
      | Some e -> Pat_Axiom(Axiom_Instr(i_rnd (lv,e)))
    end
  | _ -> Pat_Fun_Symbol(Sym_Instr_Sample,[plv;pe])

let p_call (olv : pattern option) (f : pattern) (args : pattern list) =
  let get_expr = function
    | Pat_Axiom(Axiom_Form f) -> expr_of_form f
    | _ -> None in
  match olv,f with
  | None,Pat_Axiom(Axiom_Xpath proc) -> begin
      match olist_all get_expr args with
      | Some args -> Pat_Axiom(Axiom_Instr(i_call(None,proc,args)))
      | None -> Pat_Fun_Symbol(Sym_Instr_Call,f::args)
    end
  | Some(Pat_Axiom(Axiom_Lvalue lv) as olv),Pat_Axiom(Axiom_Xpath proc) ->
     begin
       match olist_all get_expr args with
       | Some args -> Pat_Axiom(Axiom_Instr(i_call(Some lv,proc,args)))
       | None -> Pat_Fun_Symbol(Sym_Instr_Call_Lv,olv::f::args)
     end
  | None,_ -> Pat_Fun_Symbol(Sym_Instr_Call,f::args)
  | Some lv,_ -> Pat_Fun_Symbol(Sym_Instr_Call_Lv,lv::f::args)

let p_instr_if (pcond : pattern) (ps1 : pattern) (ps2 : pattern) =
  match pcond, ps1, ps2 with
  | Pat_Axiom(Axiom_Form f),Pat_Axiom(Axiom_Stmt s1),Pat_Axiom(Axiom_Stmt s2) ->
     odfl (Pat_Fun_Symbol(Sym_Instr_If,[pcond;ps1;ps2]))
       (omap (fun cond -> Pat_Axiom(Axiom_Instr(i_if(cond,s1,s2))))
          (expr_of_form f))
  | _ -> Pat_Fun_Symbol(Sym_Instr_If,[pcond;ps1;ps2])

let p_while (pcond : pattern) (ps : pattern) =
  match pcond, ps with
  | Pat_Axiom(Axiom_Form f),Pat_Axiom(Axiom_Stmt s) ->
     odfl (Pat_Fun_Symbol(Sym_Instr_While,[pcond;ps]))
       (omap (fun cond -> Pat_Axiom(Axiom_Instr(i_while(cond,s))))
          (expr_of_form f))
  | _ -> Pat_Fun_Symbol(Sym_Instr_While,[pcond;ps])

let p_assert (p : pattern) = match p with
  | Pat_Axiom(Axiom_Form f) ->
     odfl (Pat_Fun_Symbol(Sym_Instr_Assert,[p]))
       (omap (fun e -> Pat_Axiom(Axiom_Instr(i_assert e))) (expr_of_form f))
  | _ -> Pat_Fun_Symbol(Sym_Instr_Assert,[p])

(* -------------------------------------------------------------------------- *)

module Psubst = struct

  type p_subst = {
      ps_freshen : bool;
      ps_patloc  : pattern             Mid.t;
      ps_mp      : mpath               Mid.t;
      ps_mem     : ident               Mid.t;
      ps_opdef   : (ident list * expr) Mp.t;
      ps_pddef   : (ident list * form) Mp.t;
      ps_exloc   : expr                Mid.t;
      ps_sty     : ty_subst;
    }

  let p_subst_id = {
      ps_freshen = false;
      ps_patloc  = Mid.empty;
      ps_mp      = Mid.empty;
      ps_mem     = Mid.empty;
      ps_opdef   = Mp.empty;
      ps_pddef   = Mp.empty;
      ps_exloc   = Mid.empty;
      ps_sty     = ty_subst_id;
    }

  let is_subst_id s =
       s.ps_freshen = false
    && is_ty_subst_id s.ps_sty
    && Mid.is_empty   s.ps_patloc
    && Mid.is_empty   s.ps_mem
    && Mp.is_empty    s.ps_opdef
    && Mp.is_empty    s.ps_pddef
    && Mid.is_empty   s.ps_exloc

  let p_subst_init ?mods ?sty ?opdef ?prdef () =
    { p_subst_id with
      ps_mp    = odfl Mid.empty mods;
      ps_sty   = odfl ty_subst_id sty;
      ps_opdef = odfl Mp.empty opdef;
      ps_pddef = odfl Mp.empty prdef;
    }

  let p_bind_local (s : p_subst) (id : ident) (p : pattern) =
    let merge o = assert (o = None); Some p in
    { s with ps_patloc = Mid.change merge id s.ps_patloc }

  let p_bind_mem (s : p_subst) (m1 : memory) (m2 : memory) =
    let merge o = assert (o = None); Some m2 in
    { s with ps_mem = Mid.change merge m1 s.ps_mem }

  let p_bind_mod (s : p_subst) (x : ident) (m : mpath) =
    let merge o = assert (o = None); Some m in
    { s with ps_mp = Mid.change merge x s.ps_mp }

  let p_bind_rename (s : p_subst) (nfrom : ident) (nto : ident) (ty : ty) =
    let np = pat_local nto ty in
    let ne = e_local nto ty in
    let s = p_bind_local s nfrom np in
    let merge o = assert (o = None); Some ne in
    { s with ps_exloc = Mid.change merge nfrom s.ps_exloc }

  (* ------------------------------------------------------------------------ *)
  let p_rem_local (s : p_subst) (n : ident) =
    { s with ps_patloc = Mid.remove n s.ps_patloc;
             ps_exloc  = Mid.remove n s.ps_exloc; }

  let p_rem_mem (s : p_subst) (m : memory) =
    { s with ps_mem = Mid.remove m s.ps_mem }

  let p_rem_mod (s : p_subst) (m : ident) =
    let smp = Mid.remove m s.ps_mp in
    let sty = s.ps_sty in
    let sty = { sty with ts_mp = EcPath.m_subst sty.ts_p smp } in
    { s with ps_mp = smp; ps_sty = sty; }

  (* ------------------------------------------------------------------------ *)
  let add_local (s : p_subst) (n,t as nt : ident * ty) =
    let n' = if s.ps_freshen then EcIdent.fresh n else n in
    let t' = (ty_subst s.ps_sty) t in
    if   n == n' && t == t'
    then (s, nt)
    else (p_bind_rename s n n' t'), (n',t')

  let add_locals = List.Smart.map_fold add_local

  let subst_lpattern (s : p_subst) (lp : lpattern) =
    match lp with
    | LSymbol x ->
        let (s, x') = add_local s x in
          if x == x' then (s, lp) else (s, LSymbol x')

    | LTuple xs ->
        let (s, xs') = add_locals s xs in
          if xs == xs' then (s, lp) else (s, LTuple xs')

    | LRecord (p, xs) ->
        let (s, xs') =
          List.Smart.map_fold
            (fun s ((x, t) as xt) ->
              match x with
              | None ->
                  let t' = (ty_subst s.ps_sty) t in
                    if t == t' then (s, xt) else (s, (x, t'))
              | Some x ->
                  let (s, (x', t')) = add_local s (x, t) in
                    if   x == x' && t == t'
                    then (s, xt)
                    else (s, (Some x', t')))
            s xs
        in
          if xs == xs' then (s, lp) else (s, LRecord (p, xs'))

  let gty_subst (s : p_subst) (gty : gty) =
    if is_subst_id s then gty else

    match gty with
    | GTty ty ->
        let ty' = (ty_subst s.ps_sty) ty in
        if ty == ty' then gty else GTty ty'

    | GTmodty (p, (rx, r)) ->
        let sub  = s.ps_sty.ts_mp in
        let xsub = EcPath.x_substm s.ps_sty.ts_p s.ps_mp in
        let p'   = mty_subst s.ps_sty.ts_p sub p in
        let rx'  = Sx.fold (fun m rx' -> Sx.add (xsub m) rx') rx Sx.empty in
        let r'   = Sm.fold (fun m r' -> Sm.add (sub m) r') r Sm.empty in

        if   p == p' && Sx.equal rx rx' && Sm.equal r r'
        then gty
        else GTmodty (p', (rx', r'))

    | GTmem mt ->
        let mt' = EcMemory.mt_substm s.ps_sty.ts_p s.ps_mp
                    (ty_subst s.ps_sty) mt in
        if mt == mt' then gty else GTmem mt'

  (* ------------------------------------------------------------------------ *)
  let add_binding (s : p_subst) (x,gty as xt : binding) =
    let gty' = gty_subst s gty in
    let x'   = if s.ps_freshen then EcIdent.fresh x else x in
    if   x == x' && gty == gty'
    then
      let s = match gty with
        | GTty _    -> p_rem_local s x
        | GTmodty _ -> p_rem_mod   s x
        | GTmem _   -> p_rem_mem   s x in
      (s,xt)
    else
      let s = match gty' with
        | GTty   ty -> p_bind_rename s x x' ty
        | GTmodty _ -> p_bind_mod s x (EcPath.mident x')
        | GTmem   _ -> p_bind_mem s x x'
      in
      (s, (x', gty'))

  let add_bindings = List.map_fold add_binding

  (* ------------------------------------------------------------------------ *)
  let p_subst (_s : p_subst) (p : pattern) = p

end


(* -------------------------------------------------------------------------- *)
let rec p_betared_opt = function
  | Pat_Anything -> None
  | Pat_Meta_Name (p,n) ->
     omap (fun p -> Pat_Meta_Name (p,n)) (p_betared_opt p)
  | Pat_Sub p ->
     omap (fun p -> Pat_Sub p) (p_betared_opt p)
  | Pat_Or [p] -> p_betared_opt p
  | Pat_Or _ -> None
  | Pat_Instance _ -> assert false
  | Pat_Type (p,gty) ->
     omap (fun p -> Pat_Type(p,gty)) (p_betared_opt p)
  | Pat_Red_Strat (p,f) ->
     omap (fun p -> Pat_Red_Strat (p,f)) (p_betared_opt p)
  | Pat_Axiom (Axiom_Form f) ->
     let f2 = try EcFol.f_betared f with
              | _ -> f in
     if f_equal f f2 then None
     else Some (Pat_Axiom(Axiom_Form f2))
  | Pat_Axiom _ -> None
  | Pat_Fun_Symbol (s,lp) ->
     match s,lp with
     | Sym_Form_App ty,
       (Pat_Fun_Symbol(Sym_Form_Quant(Llambda, bds),[p]))::pargs ->
        let (bs1,bs2),(pargs1,pargs2) = List.prefix2 bds pargs in
        let subst = Psubst.p_subst_id in
        let subst =
          List.fold_left2 (fun s (id,_) p -> Psubst.p_bind_local s id p)
            subst bs1 pargs1 in
        Some (p_app (p_f_quant Llambda bs2 (Psubst.p_subst subst p)) pargs2 (Some ty))
     | Sym_App,
       (Pat_Fun_Symbol(Sym_Form_Quant(Llambda, bds),[p]))::pargs ->
        let (bs1,bs2),(pargs1,pargs2) = List.prefix2 bds pargs in
        let subst = Psubst.p_subst_id in
        let subst =
          List.fold_left2 (fun s (id,_) p -> Psubst.p_bind_local s id p)
            subst bs1 pargs1 in
        Some (p_app (p_f_quant Llambda bs2 (Psubst.p_subst subst p)) pargs2 None)
     | Sym_Form_App ty,
       (Pat_Fun_Symbol(Sym_Quant(Llambda, bds),[p]))::pargs ->
        let (bs1,bs2),(pargs1,pargs2) = List.prefix2 bds pargs in
        let subst = Psubst.p_subst_id in
        let subst =
          List.fold_left2 (fun s (id,_) p -> Psubst.p_bind_local s id p)
            subst bs1 pargs1 in
        Some (p_app (p_quant Llambda bs2 (Psubst.p_subst subst p)) pargs2 (Some ty))
     | Sym_App,
       (Pat_Fun_Symbol(Sym_Quant(Llambda, bds),[p]))::pargs ->
        let (bs1,bs2),(pargs1,pargs2) = List.prefix2 bds pargs in
        let subst = Psubst.p_subst_id in
        let subst =
          List.fold_left2 (fun s (id,_) p -> Psubst.p_bind_local s id p)
            subst bs1 pargs1 in
        Some (p_app (p_quant Llambda bs2 (Psubst.p_subst subst p)) pargs2 None)
     | _ -> None


(* -------------------------------------------------------------------------- *)

let p_destr_app = function
  | Pat_Axiom(Axiom_Form f) ->
     let p,lp = EcFol.destr_app f in
     pat_form p, List.map pat_form lp
  | Pat_Fun_Symbol(Sym_Form_App _,p::lp)
    | Pat_Fun_Symbol(Sym_App, p::lp) -> p,lp
  | p -> p, []

(* -------------------------------------------------------------------------- *)
let p_true  = Pat_Axiom(Axiom_Form EcFol.f_true)
let p_false = Pat_Axiom(Axiom_Form EcFol.f_false)

let p_is_true = function
  | Pat_Axiom(Axiom_Form f) -> EcCoreFol.is_true f
  | _ -> false

let p_is_false = function
  | Pat_Axiom(Axiom_Form f) -> EcCoreFol.is_false f
  | _ -> false

let p_bool_val p =
  if p_is_true p then Some true
  else if p_is_false p then Some false
  else None

let p_not = function
  | Pat_Axiom(Axiom_Form f) -> Pat_Axiom(Axiom_Form (EcFol.f_not f))
  | p -> p_app (Pat_Axiom(Axiom_Form EcFol.fop_not)) [p] (Some EcTypes.tbool)

let p_imp (p1 : pattern) (p2 : pattern) = match p1,p2 with
  | Pat_Axiom(Axiom_Form f1),
    Pat_Axiom(Axiom_Form f2) ->
     Pat_Axiom(Axiom_Form (EcFol.f_imp f1 f2))
  | _ -> p_app (Pat_Axiom(Axiom_Form EcFol.fop_imp)) [p1;p2]
           (Some EcTypes.tbool)

let p_anda (p1 : pattern) (p2 : pattern) = match p1,p2 with
  | Pat_Axiom(Axiom_Form f1),
    Pat_Axiom(Axiom_Form f2) ->
     Pat_Axiom(Axiom_Form (EcFol.f_anda f1 f2))
  | _ -> p_app (Pat_Axiom(Axiom_Form EcFol.fop_anda)) [p1;p2]
           (Some EcTypes.tbool)

(* -------------------------------------------------------------------------- *)
let p_is_not = function
  | Pat_Axiom(Axiom_Form f) -> EcFol.is_not f
  | _ -> false

let p_destr_not = function
  | Pat_Axiom(Axiom_Form f) -> Pat_Axiom(Axiom_Form (EcFol.destr_not f))
  | _ -> assert false

(* -------------------------------------------------------------------------- *)
let p_not_simpl (p : pattern) =
  if p_is_not p then p_destr_not p
  else if p_is_true p then p_false
  else if p_is_false p then p_true
  else p_not p

let p_imp_simpl (p1 : pattern) (p2 : pattern) =
  if p_is_true p1 then p2
  else if p_is_false p1 || p_is_true p2 then p_true
  else if p_is_false p2 then p_not_simpl p1
  else if p_equal p1 p2 then p_true
  else p_imp p1 p2

let p_anda_simpl (p1 : pattern) (p2 : pattern) =
  if p_is_true p1 then p2
  else if p_is_false p1 then p_false
  else if p_is_true p2 then p1
  else if p_is_false p2 then p_false
  else p_anda p1 p2

(* -------------------------------------------------------------------------- *)
let p_if_simpl (p1 : pattern) (p2 : pattern) (p3 : pattern) =
  if p_equal p2 p3 then p2
  else match p_bool_val p1, p_bool_val p2, p_bool_val p3 with
  | Some true, _, _  -> p2
  | Some false, _, _ -> p3
  | _, Some true, _  -> p_imp_simpl (p_not_simpl p1) p3
  | _, Some false, _ -> p_anda_simpl (p_not_simpl p1) p3
  | _, _, Some true  -> p_imp_simpl p1 p2
  | _, _, Some false -> p_anda_simpl p1 p2
  | _, _, _          -> p_if p1 p2 p3

let p_proj_simpl (p1 : pattern) (i : int) (ty : ty) =
  match p1 with
  | Pat_Fun_Symbol(Sym_Form_Tuple,pargs) -> List.nth pargs i
  | Pat_Axiom(Axiom_Form f) -> Pat_Axiom(Axiom_Form (f_proj_simpl f i ty))
  | _ -> p_proj p1 i ty

let p_app_simpl_opt op pargs ty = match op with
  | None -> None
  | Some p -> p_betared_opt (Pat_Fun_Symbol(Sym_Form_App ty,p::pargs))

let p_forall_simpl b p =
  let b = List.filter (fun (id,_) -> Mid.mem id (pat_fv p)) b in
  p_f_forall b p

let p_exists_simpl b p =
  let b = List.filter (fun (id,_) -> Mid.mem id (pat_fv p)) b in
  p_f_exists b p
