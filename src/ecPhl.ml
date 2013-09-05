(* -------------------------------------------------------------------- *)
open EcParsetree
open EcUtils
open EcIdent
open EcPath
open EcCoreLib
open EcTypes
open EcFol
open EcBaseLogic
open EcEnv
open EcPV
open EcLogic
open EcModules
open EcMetaProg
open EcCorePhl

(* -------------------------------------------------------------------- *)
class rn_hl_exists_elim = object inherit xrule "[hl] elim-exists" end
let rn_hl_exists_elim = RN_xtd (new rn_hl_exists_elim)

let t_hr_exists_elim g = 
  let concl = get_concl g in
  let pre = get_pre concl in
  let bd, pre = destr_exists pre in
  (* TODO check that bd is not bind in the post *)
  let concl = f_forall bd (set_pre ~pre concl) in
  prove_goal_by [concl] rn_hl_exists_elim g

let get_to_gen side f = 
  let do_side m = 
    if side then 
      if EcIdent.id_equal m mleft then true 
      else (assert (EcIdent.id_equal m mright); false)
    else (assert (EcIdent.id_equal m mhr); true) in
  match f.f_node with
  | Fpvar(pv,m) -> 
    let id = id_of_pv pv m in
    (id, do_side m, f_pvar pv f.f_ty, f)
  | Fglob(mp,m) ->
    assert (
      if side then EcIdent.id_equal m mleft || EcIdent.id_equal m mright
      else EcIdent.id_equal m mhr);
    let id = id_of_mp mp m in
    (id, do_side m, f_glob mp, f)
  | _ -> tacuerror "global memory or variable expected"

let get_to_gens side fs = 
  List.map (get_to_gen side) fs

let t_hr_exists_intro fs g = 
  let hyps, concl = get_goal g in 
  let pre = get_pre concl in
  let post = get_post concl in
  let side = is_equivS concl || is_equivF concl in
  let gen = get_to_gens side fs in
  let eqs = List.map (fun (id,_,_,f) -> f_eq (f_local id f.f_ty) f) gen in
  let bd = List.map (fun (id,_,_,f) -> id, GTty f.f_ty) gen in
  let pre = f_exists bd (f_and (f_ands eqs) pre) in
  let ms = 
    if side then LDecl.fresh_ids hyps ["&ml";"&mr";"H"] 
    else LDecl.fresh_ids hyps ["&m";"H"] in
  let h = List.hd (List.rev ms) in
  let args = 
    let ml = List.hd ms in
    let mr = if side then List.hd (List.tl ms) else ml in
    let do1 (_,side,mk,_) = 
      AAform (mk (if side then ml else mr)) in
    List.map do1 gen in
  t_seq_subgoal (EcPhlConseq.t_conseq pre post)
    [ t_lseq [ t_intros_i ms;
               gen_t_exists (fun _ _ f -> f) args; 
               t_hyp h ];
      t_trivial; t_id None] g

(* -------------------------------------------------------------------- *)
class rn_hl_while (_ : form) (_ : form option) (_ : (form * form) option) =
object
  inherit xrule "[hl] while"
end

let rn_hl_while x1 x2 x3 =
  RN_xtd (new rn_hl_while x1 x2 x3 :> xrule)
  
let t_hoare_while inv g =
  let env, _, concl = get_goal_e g in
  let hs = t_as_hoareS concl in
  let ((e,c),s) = s_last_while "while" hs.hs_s in
  let m = EcMemory.memory hs.hs_m in
  let e = form_of_expr m e in
      (* the body preserve the invariant *)
  let b_pre  = f_and_simpl inv e in
  let b_post = inv in
  let b_concl = f_hoareS hs.hs_m b_pre c b_post in
      (* the wp of the while *)
  let post = f_imps_simpl [f_not_simpl e; inv] hs.hs_po in
  let modi = s_write env c in
  let post = generalize_mod env m modi post in
  let post = f_and_simpl inv post in
  let concl = f_hoareS_r { hs with hs_s = s; hs_po=post} in
  prove_goal_by [b_concl;concl] (rn_hl_while inv None None) g

let t_bdHoare_while inv vrnt g =
  let env, _, concl = get_goal_e g in
  let bhs = t_as_bdHoareS concl in
  let ((e,c),s) = s_last_while "while" bhs.bhs_s in
  let m = EcMemory.memory bhs.bhs_m in
  let e = form_of_expr m e in
  (* the body preserve the invariant *)
  let k_id = EcIdent.create "z" in
  let k = f_local k_id tint in
  let vrnt_eq_k = f_eq vrnt k in
  let vrnt_lt_k = f_int_lt vrnt k in
  let b_pre  = f_and_simpl (f_and_simpl inv e) vrnt_eq_k in
  let b_post = f_and_simpl inv vrnt_lt_k in
  let b_concl = f_bdHoareS_r 
    { bhs with bhs_pr=b_pre; bhs_s=c; bhs_po=b_post;
      bhs_cmp=FHeq; bhs_bd=f_r1} 
  in
  let b_concl = f_forall_simpl [(k_id,GTty tint)] b_concl in
  (* the wp of the while *)
  let post = f_imps_simpl [f_not_simpl e; inv] bhs.bhs_po in
  let term_condition = f_imps_simpl [inv;f_int_le vrnt (f_int 0)] (f_not_simpl e) in
  let post = f_and term_condition post in
  let modi = s_write env c in
  let post = generalize_mod env m modi post in
  let post = f_and_simpl inv post in
  let concl = f_bdHoareS_r { bhs with bhs_s = s; bhs_po=post} in
  prove_goal_by [b_concl;concl] (rn_hl_while inv (Some vrnt) None) g

let t_equiv_while_disj side vrnt inv g =
  let env, _, concl = get_goal_e g in
  let es = t_as_equivS concl in
  let s,m_side,m_other = if side then es.es_sl, es.es_ml, es.es_mr 
    else es.es_sr, es.es_mr, es.es_ml in
  let ((e,c),s) = s_last_while "while" s in
  let e = form_of_expr (EcMemory.memory m_side) e in
  (* the body preserve the invariant and variant decreases *)
  let k_id = EcIdent.create "z" in
  let k = f_local k_id tint in
  let vrnt_eq_k = f_eq vrnt k in
  let vrnt_lt_k = f_int_lt vrnt k in
  let m_other' = EcIdent.create "&m",EcMemory.memtype m_other in
  let smem = Fsubst.f_bind_mem Fsubst.f_subst_id (EcMemory.memory m_side) mhr in
  let smem = Fsubst.f_bind_mem smem (EcMemory.memory m_other) (EcMemory.memory m_other') in
  let b_pre  = f_and_simpl (f_and_simpl inv e) vrnt_eq_k in
  let b_pre = Fsubst.f_subst smem b_pre in
  let b_post = f_and_simpl inv vrnt_lt_k in
  let b_post = Fsubst.f_subst smem b_post in
  let b_concl = f_bdHoareS (mhr,EcMemory.memtype m_side) b_pre c b_post FHeq f_r1 in 
  let b_concl = f_forall_simpl [(k_id,GTty tint)] b_concl in
  let b_concl = f_forall_mems [m_other'] b_concl in
      (* the wp of the while *)
  let post = f_imps_simpl [f_not_simpl e; inv] es.es_po in
  let term_condition = f_imps_simpl [inv;f_int_le vrnt (f_int 0)] (f_not_simpl e) in
  let post = f_and term_condition post in
  let modi = s_write env c in
  let post = generalize_mod env (EcMemory.memory m_side) modi post in
  let post = f_and_simpl inv post in
  let concl = if side then f_equivS_r { es with es_sl = s; es_po=post}
    else f_equivS_r { es with es_sr = s; es_po=post} in
  prove_goal_by [b_concl;concl] (rn_hl_while inv (Some vrnt) None) g

let t_equiv_while inv g =
  let env,_,concl = get_goal_e g in
  let es = t_as_equivS concl in
  let (el,cl), (er,cr), sl, sr = s_last_whiles "while" es.es_sl es.es_sr in
  let ml = EcMemory.memory es.es_ml in
  let mr = EcMemory.memory es.es_mr in
  let el = form_of_expr ml el in
  let er = form_of_expr mr er in
  let sync_cond = f_iff_simpl el er in
      (* the body preserve the invariant *)
  let b_pre  = f_ands_simpl [inv; el] er in
  let b_post = f_and_simpl inv sync_cond in
  let b_concl = f_equivS es.es_ml es.es_mr b_pre cl cr b_post in
      (* the wp of the while *)
  let post = f_imps_simpl [f_not_simpl el;f_not_simpl er; inv] es.es_po in
  let modil = s_write env cl in
  let modir = s_write env cr in
  let post = generalize_mod env mr modir post in
  let post = generalize_mod env ml modil post in
  let post = f_and_simpl inv post in
  let concl = f_equivS_r {es with es_sl = sl; es_sr = sr; es_po = post} in
  prove_goal_by [b_concl; concl] (rn_hl_while inv None None) g 

(* -------------------------------------------------------------------- *)

let wp_asgn_call env m lv res post =
  match lv with
  | None -> post
  | Some lv ->
    let lets = lv_subst m lv res in
      mk_let_of_lv_substs env ([lets],post)

let subst_args_call env m f =
  List.fold_right2 (fun v e s ->
    PVM.add env (pv_loc f v.v_name) m (form_of_expr m e) s)

class rn_hl_call side pr po =
object
  inherit xrule "[hl] call"

  method side : bool option = side
  method pre  : form = pr
  method post : form = po
end

let rn_hl_call side pr po =
  RN_xtd (new rn_hl_call side pr po :> xrule)

let t_hoare_call fpre fpost g =
  (* FIXME : check the well formess of the pre and the post ? *)
  let env,_,concl = get_goal_e g in
  let hs = t_as_hoareS concl in
  let (lp,f,args),s = s_last_call "call" hs.hs_s in
  let m = EcMemory.memory hs.hs_m in
  let fsig = (Fun.by_xpath f env).f_sig in
  (* The function satisfies the specification *)
  let f_concl = f_hoareF fpre f fpost in
  (* The wp *)
  let pvres = pv_res f in
  let vres = EcIdent.create "result" in
  let fres = f_local vres fsig.fs_ret in
  let post = wp_asgn_call env m lp fres hs.hs_po in
  let fpost = PVM.subst1 env pvres m fres fpost in 
  let modi = f_write env f in
  let post = generalize_mod env m modi (f_imp_simpl fpost post) in
  let post = f_forall_simpl [(vres, GTty fsig.fs_ret)] post in
  let spre = subst_args_call env m f fsig.fs_params args PVM.empty in
  let post = f_anda_simpl (PVM.subst env spre fpre) post in
  let concl = f_hoareS_r { hs with hs_s = s; hs_po=post} in
  prove_goal_by [f_concl;concl] (rn_hl_call None fpre fpost) g


let bdHoare_call_spec fpre fpost f cmp bd opt_bd = 
  match cmp, opt_bd with
  | FHle, Some _ -> cannot_apply "call" 
    "optional bound parameter not allowed for upper-bounded judgements"
  | FHle, None -> 
    f_bdHoareF fpre f fpost FHle bd 
  | FHeq, Some bd ->
    f_bdHoareF fpre f fpost FHeq bd 
  | FHeq, None -> 
    f_bdHoareF fpre f fpost FHeq bd 
  | FHge, Some bd -> 
    f_bdHoareF fpre f fpost FHge bd 
  | FHge, None -> 
    f_bdHoareF fpre f fpost FHge bd 
  
let t_bdHoare_call fpre fpost opt_bd g =
  (* FIXME : check the well formess of the pre and the post ? *)
  let env,_,concl = get_goal_e g in
  let bhs = t_as_bdHoareS concl in
  let (lp,f,args),s = s_last_call "call" bhs.bhs_s in
  let m = EcMemory.memory bhs.bhs_m in
  let fsig = (Fun.by_xpath f env).f_sig in

  let f_concl = bdHoare_call_spec fpre fpost f bhs.bhs_cmp bhs.bhs_bd opt_bd in

  (* The wp *)
  let pvres = pv_res f in
  let vres = EcIdent.create "result" in
  let fres = f_local vres fsig.fs_ret in
  let post = wp_asgn_call env m lp fres bhs.bhs_po in
  let fpost = PVM.subst1 env pvres m fres fpost in 
  let modi = f_write env f in
  let post = generalize_mod env m modi (f_imp_simpl fpost post) in
  let post = f_forall_simpl [(vres, GTty fsig.fs_ret)] post in
  let spre = subst_args_call env m f fsig.fs_params args PVM.empty in
  let post = f_anda_simpl (PVM.subst env spre fpre) post in

  (* most of the above code is duplicated from t_hoare_call *)
  let concl = match bhs.bhs_cmp, opt_bd with
    | FHle, None -> f_hoareS bhs.bhs_m bhs.bhs_pr s post 
    | FHeq, Some bd ->
      f_bdHoareS_r 
        { bhs with bhs_s = s; bhs_po=post; bhs_bd=f_real_div bhs.bhs_bd bd} 
    | FHeq, None -> 
      f_bdHoareS_r { bhs with bhs_s = s; bhs_po=post; bhs_bd=f_r1 } 
    | FHge, Some bd -> 
      f_bdHoareS_r 
        { bhs with bhs_s = s; bhs_po=post; bhs_bd=f_real_div bhs.bhs_bd bd} 
    | FHge, None -> 
      f_bdHoareS_r { bhs with bhs_s = s; bhs_po=post; bhs_cmp=FHeq; bhs_bd=f_r1}
    | _, _ -> assert false
  in
  prove_goal_by [f_concl;concl] (rn_hl_call None fpre fpost) g

      

let t_equiv_call fpre fpost g =
  (* FIXME : check the well formess of the pre and the post ? *)
  let env,_,concl = get_goal_e g in
  let es = t_as_equivS concl in
  let (lpl,fl,argsl),(lpr,fr,argsr),sl,sr = 
    s_last_calls "call" es.es_sl es.es_sr in
  let ml = EcMemory.memory es.es_ml in
  let mr = EcMemory.memory es.es_mr in
  let fsigl = (Fun.by_xpath fl env).f_sig in
  let fsigr = (Fun.by_xpath fr env).f_sig in
  (* The functions satisfy their specification *)
  let f_concl = f_equivF fpre fl fr fpost in
  (* The wp *)
  let pvresl = pv_res fl and pvresr = pv_res fr in
  let vresl = LDecl.fresh_id (get_hyps g) "result_L" in
  let vresr = LDecl.fresh_id (get_hyps g) "result_R" in
  let fresl = f_local vresl fsigl.fs_ret in
  let fresr = f_local vresr fsigr.fs_ret in
  let post = wp_asgn_call env ml lpl fresl es.es_po in
  let post = wp_asgn_call env mr lpr fresr post in
  let s    = 
    PVM.add env pvresl ml fresl (PVM.add env pvresr mr fresr PVM.empty) in   
  let fpost = PVM.subst env s fpost in 
  let modil = f_write env fl in
  let modir = f_write env fr in
  let post = generalize_mod env mr modir (f_imp_simpl fpost post) in
  let post = generalize_mod env ml modil post in
  let post = 
    f_forall_simpl
      [(vresl, GTty fsigl.fs_ret);
       (vresr, GTty fsigr.fs_ret)]
      post in
  let spre = subst_args_call env ml fl fsigl.fs_params argsl PVM.empty in
  let spre = subst_args_call env mr fr fsigr.fs_params argsr spre in
  let post = f_anda_simpl (PVM.subst env spre fpre) post in
  let concl = f_equivS_r { es with es_sl = sl; es_sr = sr; es_po=post} in
  prove_goal_by [f_concl;concl] (rn_hl_call None fpre fpost) g

(* TODO generalize the rule for any lossless statement *)
let t_equiv_call1 side fpre fpost g =
  let env,_,concl = get_goal_e g in
  let equiv = t_as_equivS concl in

  let (me, stmt) =
    match side with
    | true  -> (EcMemory.memory equiv.es_ml, equiv.es_sl)
    | false -> (EcMemory.memory equiv.es_mr, equiv.es_sr)
  in

  let (lp, f, args), fstmt = s_last_call "call" stmt in
  let fsig = (Fun.by_xpath f env).f_sig in

  (* The function satisfies its specification *)
  let fconcl = f_bdHoareF fpre f fpost FHeq f_r1 in

  (* WP *)
  let pvres  = pv_res f in
  let vres   = LDecl.fresh_id (get_hyps g) "result" in
  let fres   = f_local vres fsig.fs_ret in
  let post   = wp_asgn_call env me lp fres equiv.es_po in
  let subst  = PVM.add env pvres me fres PVM.empty in
  let msubst = Fsubst.f_bind_mem Fsubst.f_subst_id EcFol.mhr me in
  let fpost  = PVM.subst env subst (Fsubst.f_subst msubst fpost) in
  let modi   = f_write env f in
  let post   = f_imp_simpl fpost post in
  let post   = generalize_mod env me modi post in
  let post   = f_forall_simpl [(vres, GTty fsig.fs_ret)] post in
  let spre   = PVM.empty in
  let spre   = subst_args_call env me f fsig.fs_params args spre in
  let post   = 
    f_anda_simpl (PVM.subst env spre (Fsubst.f_subst msubst fpre)) post in
  let concl  =
    match side with
    | true  -> { equiv with es_sl = fstmt; es_po = post; }
    | false -> { equiv with es_sr = fstmt; es_po = post; } in
  let concl  = f_equivS_r concl in
  prove_goal_by [fconcl; concl] (rn_hl_call (Some side) fpre fpost) g

(* --------------------------------------------------------------------- *)
class rn_hl_hoare_equiv = object inherit xrule "[hl] hoare-equiv" end
let rn_hl_hoare_equiv = RN_xtd (new rn_hl_hoare_equiv)

let t_hoare_equiv p q p1 q1 p2 q2 g =
  let concl = get_concl g in
  let es = t_as_equivS concl in
  let s1 = Fsubst.f_bind_mem Fsubst.f_subst_id mhr (fst es.es_ml) in
  let s2 = Fsubst.f_bind_mem Fsubst.f_subst_id mhr (fst es.es_mr) in
  let concl1 = 
    f_forall_mems [es.es_ml;es.es_mr] 
      (f_imp es.es_pr (f_and p (f_and (Fsubst.f_subst s1 p1) (Fsubst.f_subst s2 p2)))) in
  let concl2 = 
    f_forall_mems [es.es_ml;es.es_mr]
      (f_imps [q;Fsubst.f_subst s1 q1;Fsubst.f_subst s2 q2] es.es_po) in
  let concl3 = 
    f_hoareS (mhr,snd es.es_ml) p1 es.es_sl q1 in
  let concl4 = 
    f_hoareS (mhr,snd es.es_mr) p2 es.es_sr q2 in
  let concl5 = 
    f_equivS_r { es with es_pr = p; es_po = q } in
  prove_goal_by [concl1; concl2; concl3; concl4; concl5] 
    rn_hl_hoare_equiv g

(*
let t_equiv_mod 
{P} c1 ~ c2 {Q}
P => forall mod, Q => Q' 
-------------------------
{P} c1 ~ c2 {Q'}
*)

(*
let t_equiv_true 
lossless c1
lossless c2
------------------
{P} c1 ~ c2 {true}

*)

(* --------------------------------------------------------------------- *)
let _inline hyps me sp s =
  let env = LDecl.toenv hyps in
  let module P = EcPath in

  let inline1 me lv p args = 
    let p = EcEnv.NormMp.norm_xpath env p in
    let f = EcEnv.Fun.by_xpath p env in
    let fdef = 
      match f.f_def with
      | FBdef def -> def 
      | _ -> begin
        let ppe = EcPrinting.PPEnv.ofenv env in
        tacuerror
          "Abstract function `%a' cannot be inlined"
          (EcPrinting.pp_funname ppe) p
      end
    in
    let me, anames = 
      List.map_fold fresh_pv me f.f_sig.fs_params in
    let me, lnames = 
      List.map_fold fresh_pv me fdef.f_locals in
    let subst =
      let for1 mx v x =
        (* Remark p is in normal form so (P.xqname p v.v_name) is *)
        P.Mx.add
          (P.xqname p v.v_name)
          (P.xqname (EcMemory.xpath me) x)
          mx
      in
      let mx = P.Mx.empty in
      let mx = List.fold_left2 for1 mx f.f_sig.fs_params anames in
      let mx = List.fold_left2 for1 mx fdef.f_locals lnames in
      let on_xp xp =
        let xp' = EcEnv.NormMp.norm_xpath env xp in
        P.Mx.find_def xp xp' mx 
      in
      { e_subst_id with es_xp = on_xp }
    in

    let prelude =
      List.map2
        (fun (v, newx) e ->
          let newpv = pv_loc (EcMemory.xpath me) newx in
          i_asgn (LvVar (newpv, v.v_type), e))
        (List.combine f.f_sig.fs_params anames)
        args in

    let body  = s_subst subst fdef.f_body in

    let resasgn =
      match fdef.f_ret with
      | None   -> None
      | Some r -> Some (i_asgn (oget lv, e_subst subst r)) in

    me, prelude @ body.s_node @ (otolist resasgn) in

  let rec inline_i me ip i = 
    match ip, i.i_node with
    | IPpat, Scall (lv, p, args) -> 
      inline1 me lv p args 
    | IPif(sp1, sp2), Sif(e,s1,s2) ->
      let me,s1 = inline_s me sp1 s1.s_node in
      let me,s2 = inline_s me sp2 s2.s_node in
      me, [i_if(e,stmt s1, stmt s2)]
    | IPwhile sp, Swhile(e,s) ->
      let me,s = inline_s me sp s.s_node in
      me, [i_while(e,stmt s)]
    | _, _ -> assert false (* FIXME error message *)
  and inline_s me sp s = 
    match sp with
    | [] -> me, s
    | (toskip,ip)::sp ->
      let r,i,s = List.split_n toskip s in
      let me,si = inline_i me ip i in
      let me,s = inline_s me sp s in
      me, List.rev_append r (si @ s) in
  let me, s = inline_s me sp s.s_node in
  me, stmt s 

class rn_hl_inline side pattern =
object
  inherit xrule "[hl] inline"

  method side    : bool option = side
  method pattern : s_pat       = pattern
end

let rn_hl_inline side pattern =
  RN_xtd (new rn_hl_inline side pattern :> xrule)

let t_inline_bdHoare sp g =
  let hyps,concl = get_goal g in
  let hoare      = t_as_bdHoareS concl in
  let (me, stmt) = _inline hyps hoare.bhs_m sp hoare.bhs_s in
  let concl      = f_bdHoareS_r { hoare with bhs_m = me; bhs_s = stmt; } in
  prove_goal_by [concl] (rn_hl_inline None sp) g

let t_inline_hoare sp g =
  let hyps,concl = get_goal g in
  let hoare      = t_as_hoareS concl in
  let (me, stmt) = _inline hyps hoare.hs_m sp hoare.hs_s in
  let concl      = f_hoareS_r { hoare with hs_m = me; hs_s = stmt; } in
  prove_goal_by [concl] (rn_hl_inline None sp) g

let t_inline_equiv side sp g =
  let hyps,concl = get_goal g in
  let equiv = t_as_equivS concl in
  let concl =
    match side with
    | true  ->
      let (me, stmt) = _inline hyps equiv.es_ml sp equiv.es_sl in
      f_equivS_r { equiv with es_ml = me; es_sl = stmt; }
    | false ->
      let (me, stmt) = _inline hyps equiv.es_mr sp equiv.es_sr in
      f_equivS_r { equiv with es_mr = me; es_sr = stmt; }
  in
  prove_goal_by [concl] (rn_hl_inline (Some side) sp) g

(* -------------------------------------------------------------------- *)
class rn_hl_deno = object inherit xrule "[hl] deno" end
let rn_hl_deno = RN_xtd (new rn_hl_deno)

let t_bdHoare_deno pre post g =
  let env,_,concl = get_goal_e g in
  let cmp, f, bd, concl_post =
    match concl.f_node with
    | Fapp({f_node = Fop(op,_)}, [f;bd]) when is_pr f &&
        EcPath.p_equal op EcCoreLib.p_real_le ->
      FHle, f, bd, fun ev -> f_imp_simpl ev post
    | Fapp({f_node = Fop(op,_)}, [f;bd]) when is_pr f &&
        EcPath.p_equal op EcCoreLib.p_eq ->
      FHeq, f, bd, f_iff_simpl post
    | Fapp({f_node = Fop(op,_)}, [bd;f]) when is_pr f &&
        (EcPath.p_equal op EcCoreLib.p_eq) ->
      FHeq, f, bd, f_iff_simpl post
    | Fapp({f_node = Fop(op,_)}, [bd;f]) when is_pr f &&
        EcPath.p_equal op EcCoreLib.p_real_le ->
      FHge, f, bd, f_imp_simpl post
    | _ -> cannot_apply "hoare_deno" "" (* FIXME error message *)
  in 
  let (m,f,args,ev) = destr_pr f in
  let concl_e = f_bdHoareF pre f post cmp bd in
  let fun_ = EcEnv.Fun.by_xpath f env in
  (* building the substitution for the pre *)
  let sargs = 
    List.fold_left2 (fun s v a -> PVM.add env (pv_loc f v.v_name) mhr a s)
      PVM.empty fun_.f_sig.fs_params args in
  let smem = Fsubst.f_bind_mem Fsubst.f_subst_id mhr m in
  let concl_pr  = Fsubst.f_subst smem (PVM.subst env sargs pre) in
  (* building the substitution for the post *)
  (* FIXME: *)
  (* let smem_ = Fsubst.f_bind_mem Fsubst.f_subst_id mhr mhr in  *)
  (* let ev   = Fsubst.f_subst smem_ ev in *)
  let me = EcEnv.Fun.actmem_post mhr f fun_ in
  let concl_po = f_forall_mems [me] (concl_post ev) in
  prove_goal_by [concl_e;concl_pr;concl_po] rn_hl_deno g  

let t_equiv_deno pre post g =
  let env, _, concl = get_goal_e g in
  let cmp, f1, f2 =
    match concl.f_node with
    | Fapp({f_node = Fop(op,_)}, [f1;f2]) when is_pr f1 && is_pr f2 &&
        (EcPath.p_equal op EcCoreLib.p_eq || 
           EcPath.p_equal op EcCoreLib.p_real_le) ->
      EcPath.p_equal op EcCoreLib.p_eq, f1, f2
    | _ -> cannot_apply "equiv_deno" "" in (* FIXME error message *)
  let (ml,fl,argsl,evl) = destr_pr f1 in
  let (mr,fr,argsr,evr) = destr_pr f2 in
  let concl_e = f_equivF pre fl fr post in
  let funl = EcEnv.Fun.by_xpath fl env in
  let funr = EcEnv.Fun.by_xpath fr env in
  (* building the substitution for the pre *)
  (* we should substitute param by args and left by ml and right by mr *)
  let sargs = 
    List.fold_left2 (fun s v a -> PVM.add env (pv_loc fr v.v_name) mright a s)
      PVM.empty funr.f_sig.fs_params argsr in
  let sargs = 
    List.fold_left2 (fun s v a -> PVM.add env (pv_loc fl v.v_name) mleft a s)
      sargs funl.f_sig.fs_params argsl in
  let smem = 
    Fsubst.f_bind_mem (Fsubst.f_bind_mem Fsubst.f_subst_id mright mr) mleft ml in
  let concl_pr  = Fsubst.f_subst smem (PVM.subst env sargs pre) in
  (* building the substitution for the post *)
  let smeml = Fsubst.f_bind_mem Fsubst.f_subst_id mhr mleft in 
  let smemr = Fsubst.f_bind_mem Fsubst.f_subst_id mhr mright in
  let evl   = Fsubst.f_subst smeml evl and evr = Fsubst.f_subst smemr evr in
  let cmp   = if cmp then f_iff else f_imp in 
  let mel = EcEnv.Fun.actmem_post mleft fl funl in
  let mer = EcEnv.Fun.actmem_post mright fr funr in
  let concl_po = f_forall_mems [mel;mer] (f_imp post (cmp evl evr)) in
  prove_goal_by [concl_e;concl_pr;concl_po] rn_hl_deno g  

(* -------------------------------------------------------------------- *)
(* FAILURE EVENT LEMMA  *)

class rn_hl_fel cntr ash q fevent preds =
object
  inherit xrule "[hl] FEL"

  method cntr   : form = cntr
  method ash    : form = ash
  method q      : form = q
  method fevent : form = fevent
  method preds  : (xpath * form) list = preds
end

let rn_hl_fel cntr ash q fevent preds =
  RN_xtd (new rn_hl_fel cntr ash q fevent preds :> xrule)

(* takes an xpath, returns xpath set *)
let rec callable_oracles_f env modv os f =
  let f' = NormMp.norm_xpath env f in
  let func = Fun.by_xpath f' env in
  match func.f_def with
    | FBabs oi ->
      let called_fs = 
        List.fold_left (fun s o -> 
          if PV.indep env modv (f_write env o) then s else EcPath.Sx.add o s)
          EcPath.Sx.empty oi.oi_calls
      in
      List.fold_left (callable_oracles_f env modv)  os (EcPath.Sx.elements called_fs)
        
    | FBdef fdef ->
      let called_fs = 
        List.fold_left (fun s o -> 
          if PV.indep env modv (f_write env o) then s else EcPath.Sx.add o s)
          EcPath.Sx.empty fdef.f_uses.us_calls
      in
      let f_written = f_write ~except_fs:called_fs env f in
      if PV.indep env f_written modv then
        List.fold_left (callable_oracles_f env modv)  os (EcPath.Sx.elements called_fs)
      else
        EcPath.Sx.add f os
          
and callable_oracles_s env modv os s =
  callable_oracles_is env modv os s.s_node
and callable_oracles_is env modv os is = 
  List.fold_left (callable_oracles_i env modv) os is
and callable_oracles_i env modv os i = 
  match i.i_node with
    | Scall(_,f,_) -> callable_oracles_f env modv os f
    | Sif (_,s1,s2) -> callable_oracles_s env modv (callable_oracles_s env modv os s1) s2
    | Swhile (_,s) -> callable_oracles_s env modv os s
    | Sasgn _ | Srnd _ | Sassert _ -> os 

let callable_oracles_stmt env (modv:PV.t) = callable_oracles_s env modv EcPath.Sx.empty

let t_failure_event at_pos cntr ash q f_event pred_specs inv g =
  let env,_,concl = get_goal_e g in
  match concl.f_node with
    | Fapp ({f_node=Fop(op,_)},[pr;bd]) when is_pr pr 
        && EcPath.p_equal op EcCoreLib.p_real_le ->
      let (m,f,_args,ev) = destr_pr pr in
      let m = match Memory.byid m env with 
        | Some m -> m 
        | None -> cannot_apply "fel" "Cannot find memory (bug?)"
      in
      let memenv, fdef, _env = 
        try Fun.hoareS f env
        with _ -> 
          cannot_apply "fel" "not applicable to abstract functions"
      in
      let s_hd,s_tl = s_split "fel" at_pos fdef.f_body in
      let fv = PV.fv env mhr f_event in
      let os = callable_oracles_stmt env fv (stmt s_tl) in
      (* check that bad event is only modified in oracles *)
      let fv = PV.fv env mhr f_event in
      let written_except_os = s_write ~except_fs:os env (stmt s_tl) in
      if not (PV.indep env written_except_os fv ) then
        tacuerror "fail event is modified outside oracles, ie: @. @[%a@] is not disjoint to @[%a@]@." 
          (PV.pp env) written_except_os (PV.pp env) fv;
      (* subgoal on the bounds *)
      let bound_goal = 
        let intval = f_int_intval (f_int 0) (f_int_sub q (f_int 1)) in
        let v = f_int_sum ash intval treal in
        f_real_le v bd
      in
      (* we must quantify over memories *)
      let mo = EcIdent.create "&m" in
      let post_goal = 
        let subst = Fsubst.f_bind_mem Fsubst.f_subst_id mhr mo in
        let p = f_imp ev (f_and f_event (f_int_le cntr q)) in
        let p = Fsubst.f_subst subst p in
        f_forall_mems [mo, EcMemory.memtype m] p 
      in
      (* not fail and cntr=0 holds at designated program point *)
      let init_goal = 
        let p = f_and (f_not f_event) (f_eq cntr (f_int 0)) in
        let p = f_and_simpl p inv in
        f_hoareS memenv f_true (stmt s_hd) p
      in
      let oracle_goal o = 
        let not_F_to_F_goal = 
          let bound = f_app_simpl ash [cntr] treal in
          let pre = f_and (f_int_le (f_int 0) cntr) (f_not f_event) in
          let pre = f_and_simpl pre inv in
          let post = f_event in
          f_bdHoareF pre o post FHle bound
        in
        let old_cntr_id = EcIdent.create "c" in
        let old_b_id = EcIdent.create "b" in
        let old_cntr = f_local old_cntr_id tint in
        let old_b = f_local old_b_id tbool in
        let _,some_p = 
          try 
            List.find (fun (o',_) -> o=o') pred_specs 
          with Not_found ->
            o,f_true
            (* tacuerror "Cannot find precondition for oracle %s" (EcPath.x_tostring o) *)
        in
        let cntr_decr_goal = 
          let pre  = f_and some_p (f_eq old_cntr cntr) in
          let pre = f_and_simpl pre inv in
          let post = f_and (f_int_lt old_cntr cntr) (f_int_le cntr q) in
          let post = f_and_simpl post inv in
          f_forall_simpl [old_cntr_id,GTty tint] 
            (f_hoareF pre o post)
        in
        let cntr_stable_goal =
          let pre  = f_ands [f_not some_p;f_eq f_event old_b;f_eq cntr old_cntr] in
          let pre = f_and_simpl pre inv in
          let post = f_ands [f_eq f_event old_b;f_eq cntr old_cntr] in
          let post = f_and_simpl post inv in
          f_forall_simpl [old_b_id,GTty tbool; old_cntr_id,GTty tint] 
            (f_hoareF pre o post)
        in
        [not_F_to_F_goal;cntr_decr_goal;cntr_stable_goal]
      in
      let os_goals = List.concat (List.map oracle_goal (Sx.elements os)) in
      prove_goal_by ([bound_goal;post_goal;init_goal]@os_goals) 
        (rn_hl_fel cntr ash q f_event pred_specs)  g
    | _ -> 
      cannot_apply "failure event lemma" 
        "A goal of the form Pr[ _ ] <= _ was expected"
    
(* -------------------------------------------------------------------- *)
let t_gen_cond side e g =
  let hyps = get_hyps g in
  let m1,m2,h,h1,h2 = match LDecl.fresh_ids hyps ["&m";"&m";"_";"_";"_"] with
    | [m1;m2;h;h1;h2] -> m1,m2,h,h1,h2
    | _ -> assert false in
  let t_introm = 
    if side <> None then t_intros_i [m1] else t_id None 
  in
  let t_sub b g = 
    t_seq_subgoal (EcPhlRCond.t_rcond side b 1)
      [t_lseq [t_introm; EcPhlSkip.t_skip; t_intros_i [m2;h];
               t_or  
                 (t_lseq [t_elim_hyp h; t_intros_i [h1;h2]; t_hyp h2])
                 (t_hyp h)
              ];
       t_id None] g in
  t_seq_subgoal (EcPhlCase.t_hl_case e) [t_sub true; t_sub false] g

let t_hoare_cond g = 
  let concl = get_concl g in
  let hs = t_as_hoareS concl in 
  let (e,_,_) = fst (s_first_if "if" hs.hs_s) in
  t_gen_cond None (form_of_expr (EcMemory.memory hs.hs_m) e) g

let t_bdHoare_cond g = 
  let concl = get_concl g in
  let bhs = t_as_bdHoareS concl in 
  let (e,_,_) = fst (s_first_if "if" bhs.bhs_s) in
  t_gen_cond None (form_of_expr (EcMemory.memory bhs.bhs_m) e) g

let rec t_equiv_cond side g =
  let hyps,concl = get_goal g in
  let es = t_as_equivS concl in
  match side with
  | Some s ->
    let e = 
      if s then 
        let (e,_,_) = fst (s_first_if "if" es.es_sl) in
        form_of_expr (EcMemory.memory es.es_ml) e
      else
        let (e,_,_) = fst (s_first_if "if" es.es_sr) in
        form_of_expr (EcMemory.memory es.es_mr) e in
    t_gen_cond side e g
  | None -> 
      let el,_,_ = fst (s_first_if "if" es.es_sl) in
      let er,_,_ = fst (s_first_if "if" es.es_sr) in
      let el = form_of_expr (EcMemory.memory es.es_ml) el in
      let er = form_of_expr (EcMemory.memory es.es_mr) er in
      let fiff = f_forall_mems [es.es_ml;es.es_mr] (f_imp es.es_pr (f_iff el er)) in
      let hiff,m1,m2,h,h1,h2 = 
        match LDecl.fresh_ids hyps ["hiff";"&m1";"&m2";"h";"h";"h"] with 
        | [hiff;m1;m2;h;h1;h2] -> hiff,m1,m2,h,h1,h2 
        | _ -> assert false in
      let t_aux = 
        t_lseq [t_intros_i [m1];
                EcPhlSkip.t_skip;
                t_intros_i [m2;h];
                t_elim_hyp h;
                t_intros_i [h1;h2];
                t_seq_subgoal (t_rewrite_hyp `RtoL hiff 
                                 [AAmem m1;AAmem m2;AAnode])
                  [t_hyp h1; t_hyp h2]] in
      t_seq_subgoal (t_cut fiff)
        [ t_id None;
          t_seq (t_intros_i [hiff])
            (t_seq_subgoal (t_equiv_cond (Some true))
               [t_seq_subgoal (EcPhlRCond.Low.t_equiv_rcond false true  1) 
                   [t_aux; t_clear (Sid.singleton hiff)];
                t_seq_subgoal (EcPhlRCond.Low.t_equiv_rcond false false 1) 
                  [t_aux; t_clear (Sid.singleton hiff)]
               ])
        ] g

(* -------------------------------------------------------------------- *)
let t_ppr ty phi_l phi_r g =
  let env,_,concl = get_goal_e g in
  let ef = t_as_equivF concl in
  let fl,fr = ef.ef_fl,ef.ef_fr in

  let funl = EcEnv.Fun.by_xpath fl env in
  let funr = EcEnv.Fun.by_xpath fr env in
  let paramsl = funl.f_sig.fs_params in
  let paramsr = funr.f_sig.fs_params in
  let mk_local v =
    let v_id = EcIdent.create v.v_name in
    (v_id,v.v_type),f_local v_id v.v_type
  in
  let argsl = List.map mk_local paramsl in
  let argsr = List.map mk_local paramsr in


  let m1_id = EcIdent.create "&m1" in
  let m2_id = EcIdent.create "&m2" in
  let a_id = EcIdent.create "a" in
  let a_f = f_local a_id ty in

  (* let m1 = EcEnv.Fun.prF_memenv m1_id fl env in *)
  (* let m2 = EcEnv.Fun.prF_memenv m2_id fr env in *)
  (* memories must be abstract??!! *)
  let m1 = m1_id,None in
  let m2 = m2_id,None in

  let smem1 = Fsubst.f_bind_mem Fsubst.f_subst_id mleft mhr in
  let smem2 = Fsubst.f_bind_mem Fsubst.f_subst_id mright mhr in
  let phi1 = Fsubst.f_subst smem1 phi_l in
  let phi2 = Fsubst.f_subst smem2 phi_r in
  let pr1 = f_pr m1_id fl (List.map snd argsl) (f_eq a_f phi1) in
  let pr2 = f_pr m2_id fr (List.map snd argsr) (f_eq a_f phi2) in

  let concl_pr = f_eq pr1 pr2 in
  let smem =  
    Fsubst.f_bind_mem (Fsubst.f_bind_mem Fsubst.f_subst_id mright m2_id) mleft m1_id
  in
  let pre = Fsubst.f_subst smem ef.ef_pr in
  let concl = f_forall_mems [m1_id, EcMemory.memtype m1;m2_id,EcMemory.memtype m2] 
    (f_imp pre concl_pr) in
  let binders_l = List.map (fun ((v,t),_) -> v,GTty t ) argsl in
  let binders_r = List.map (fun ((v,t),_) -> v,GTty t ) argsr in
  let concl = f_forall_simpl binders_l (f_forall_simpl binders_r concl) in
  let concl = f_forall_simpl [a_id,GTty ty] concl in
  let concl_post = f_imps_simpl [f_eq phi_l a_f;f_eq phi_r a_f] ef.ef_po in
  let memenvl,_,memenvr,_,_ = Fun.equivS fl fr env in
  let concl_post = f_forall_mems [memenvl;memenvr] concl_post in
  let concl_post = f_forall_simpl [a_id,GTty ty] concl_post in
  prove_goal_by [concl_post;concl] rn_hl_deno g

class rn_hl_hoare_bd_hoare =
object
  inherit xrule "[hl] hoare-bd-hoare"
end

let rn_hl_hoare_bd_hoare =
  RN_xtd (new rn_hl_hoare_bd_hoare)

let t_hoare_bd_hoare g =
  let concl = get_concl g in
  if is_bdHoareS concl then
    let bhs = t_as_bdHoareS concl in
    let concl1 = f_hoareS bhs.bhs_m bhs.bhs_pr bhs.bhs_s (f_not bhs.bhs_po) in
    if f_equal bhs.bhs_bd f_r0 then
      prove_goal_by [concl1] rn_hl_hoare_bd_hoare g
    else 
      (* Rewrite this : it is a consequence rule *)
      let concl2 = 
        f_forall_mems [bhs.bhs_m] (f_imp bhs.bhs_pr (f_eq bhs.bhs_bd f_r0)) in
      prove_goal_by [concl1;concl2] rn_hl_hoare_bd_hoare g
  else if is_hoareS concl then
    let hs = t_as_hoareS concl in
    let concl1 = f_bdHoareS hs.hs_m hs.hs_pr hs.hs_s (f_not hs.hs_po) FHeq f_r0 in
    prove_goal_by [concl1] rn_hl_hoare_bd_hoare g
  else 
    cannot_apply "hoare/bd_hoare" "a hoare or bd_hoare judgment was expected" 

class rn_hl_prbounded =
object
  inherit xrule "[hl] pr-bounded"
end

let rn_hl_prbounded =
  RN_xtd (new rn_hl_prbounded)

let t_pr_bounded conseq g = 
  let env, _, concl = get_goal_e g in
  let m, pr, po, cmp, bd = 
    match concl.f_node with
    | FbdHoareF hf ->
      let m, _ = Fun.hoareF_memenv hf.bhf_f env in
      m, hf.bhf_pr, hf.bhf_po, hf.bhf_cmp, hf.bhf_bd 
    | FbdHoareS hf -> hf.bhs_m, hf.bhs_pr, hf.bhs_po, hf.bhs_cmp, hf.bhs_bd
    | _ -> tacuerror "bd_hoare excepted" in
  let cond = 
    match cmp with
    | FHle when f_equal bd f_r1 -> []
    | FHge when f_equal bd f_r0 -> []
    | _ when f_equal po f_false && f_equal bd f_r0 -> []
    (* TODO use the conseq rule instead *)
    | FHle when conseq -> [f_forall_mems [m] (f_imp pr (f_real_le f_r1 bd))]
    | FHge when conseq -> [f_forall_mems [m] (f_imp pr (f_real_le bd f_r0))]
    | _ -> cannot_apply "pr_bounded" "cannot solve the probabilistic judgement" in
  prove_goal_by cond rn_hl_prbounded g

let t_prbounded = t_pr_bounded true

(* TODO : Remove this : can be done by rewrite_pr *)
class rn_hl_prfalse =
object
  inherit xrule "[hl] pr-false"
end

let rn_hl_prfalse =
  RN_xtd (new rn_hl_prfalse)

let t_prfalse g = 
  let env,_, concl = get_goal_e g in
  let f,ev,bd =
    match concl.f_node with
      | Fapp ({f_node = Fop(op,_)}, [f;bd]) when is_pr f &&
          EcPath.p_equal op EcCoreLib.p_real_le
          || EcPath.p_equal op EcCoreLib.p_eq->
        let (_m,f,_args,ev) = destr_pr f in
        f,ev,bd
      | Fapp ({f_node = Fop(op,_)}, [bd;f]) when is_pr f &&
          EcPath.p_equal op EcCoreLib.p_eq->
        let (_m,f,_args,ev) = destr_pr f in
        f,ev,bd
      | _ ->
        cannot_apply "pr_false" "Pr[..] expression was expected"
  in
  (* the bound is zero *)
  let is_zero = f_real_le bd f_r0 in

  (* the event is false *)
  let smem_ = Fsubst.f_bind_mem Fsubst.f_subst_id mhr mhr in 
  let ev   = Fsubst.f_subst smem_ ev in
  let fun_ = EcEnv.Fun.by_xpath f env in
  let me = EcEnv.Fun.actmem_post mhr f fun_ in
  let concl_po = f_forall_mems [me] (f_imp f_false ev) in
  prove_goal_by [is_zero;concl_po] rn_hl_prfalse g

(** The following should be changed latter *)
class rn_hl_pr_lemma =
object
  inherit xrule "[hl] pr-lemma"
end

let rn_hl_pr_lemma =
  RN_xtd (new rn_hl_pr_lemma)

let t_pr_lemma lemma g = 
  let concl = get_concl g in
  assert (f_equal concl lemma);
  prove_goal_by [] rn_hl_pr_lemma g

let pr_false m f args = 
  f_eq (f_pr m f args f_false) f_r0

exception Found of form
      
let pr_eq env m f args p1 p2 = 
  let mem = Fun.prF_memenv mhr f env in
  let hyp = f_forall_mems [mem] (f_iff p1 p2) in
  let concl = f_eq (f_pr m f args p1) (f_pr m f args p2) in
  f_imp hyp (f_eq concl f_true)

let pr_sub env m f args p1 p2 = 
  let mem = Fun.prF_memenv mhr f env in
  let hyp = f_forall_mems [mem] (f_imp p1 p2) in
  let concl = f_real_le (f_pr m f args p1) (f_pr m f args p2) in
  f_imp hyp (f_eq concl f_true)

let pr_not m f args p = 
  f_eq (f_pr m f args (f_not p))
    (f_real_sub (f_pr m f args f_true) (f_pr m f args p))

let pr_or m f args por p1 p2 = 
  let pr1 = f_pr m f args p1 in
  let pr2 = f_pr m f args p2 in
  let pr12 = f_pr m f args (f_and p1 p2) in
  let pr = f_real_sub (f_real_add pr1 pr2) pr12 in
  f_eq (f_pr m f args (por p1 p2)) pr

let pr_disjoint env m f args por p1 p2 = 
  let mem = Fun.prF_memenv mhr f env in
  let hyp = f_forall_mems [mem] (f_not (f_and p1 p2)) in 
  let pr1 = f_pr m f args p1 in
  let pr2 = f_pr m f args p2 in
  let pr =  f_real_add pr1 pr2 in
  f_imp hyp (f_eq (f_pr m f args (por p1 p2)) pr)

let select_pr on_ev sid f = 
  match f.f_node with
  | Fpr(_,_,_,ev) -> 
      if on_ev ev && Mid.set_disjoint f.f_fv sid then raise (Found f) else false
  | _ -> false
 
let select_pr_cmp on_cmp sid f = 
  match f.f_node with
  | Fapp({f_node = Fop(op,_)},
         [{f_node = Fpr(m1,f1,arg1,_)};{f_node = Fpr(m2,f2,arg2,_)}]) ->
    if on_cmp op &&
      EcIdent.id_equal m1 m2 &&
      EcPath.x_equal f1 f2 &&
      List.all2 f_equal arg1 arg2 && 
      Mid.set_disjoint f.f_fv sid then raise (Found f) else false
  | _ -> false

let pr_rewrite_lemma = 
  ["mu_eq"      , `MuEq;
   "mu_sub"     , `MuSub;
   "mu_false"   , `MuFalse;
   "mu_not"     , `MuNot;
   "mu_or"      , `MuOr;
   "mu_disjoint", `MuDisj]

let t_pr_rewrite s g = 
  let kind = 
    try List.assoc s pr_rewrite_lemma with Not_found -> 
      tacuerror "Do not reconize %s as a probability lemma" s in
  let select = 
    match kind with 
    | `MuEq    -> select_pr_cmp (EcPath.p_equal EcCoreLib.p_eq)
    | `MuSub   -> select_pr_cmp (EcPath.p_equal EcCoreLib.p_real_le)
    | `MuFalse -> select_pr is_false
    | `MuNot   -> select_pr is_not
    | `MuOr | `MuDisj  -> select_pr is_or in
  let env, _, concl = get_goal_e g in
  let torw = 
    try ignore (EcMetaProg.FPosition.select select concl);
        tacuerror "can not find a pattern for %s" s
    with Found f -> f in
  let lemma, args = 
    match kind with
    | `MuEq | `MuSub -> 
      begin  match torw.f_node with
      | Fapp(_, [{f_node = Fpr(m,f,args,ev1)};{f_node = Fpr(_,_,_,ev2)}]) ->
        if kind = `MuEq then pr_eq env m f args ev1 ev2, [AAnode] 
        else pr_sub env m f args ev1 ev2, [AAnode]
      | _ -> assert false
      end
    | `MuFalse ->
      let m,f,args,_ = destr_pr torw in
      pr_false m f args, []
    | `MuNot ->
      let m,f,args,ev = destr_pr torw in
      let ev = destr_not ev in
      pr_not m f args ev, []
    | `MuOr ->
      let m,f,args,ev = destr_pr torw in
      let asym,ev1,ev2 = destr_or_kind ev in
      pr_or m f args (if asym then f_ora else f_or) ev1 ev2, []
    | `MuDisj ->
      let m,f,args,ev = destr_pr torw in
      let asym,ev1,ev2 = destr_or_kind ev in
      pr_disjoint env m f args (if asym then f_ora else f_or) ev1 ev2, [AAnode] in

  t_on_first (t_pr_lemma lemma)
    (t_rewrite_form `LtoR lemma args g)

let t_bdeq g = 
  let concl = get_concl g in
  let bhs = t_as_bdHoareS concl in 
  let concl = f_bdHoareS_r {bhs with bhs_cmp=FHeq } in
  prove_goal_by [concl] rn_hl_prbounded g
    
(* -------------------------------------------------------------------- *)

(* Remark for adversary case we assume that inv do not contain the
   equality of glob *)
let mk_inv_spec env inv fl fr = 
  if NormMp.is_abstract_fun fl env then 
    let (topl, _, oil, sigl), (topr, _, _, sigr) = abstract_info2 env fl fr in
    let ml, mr = mleft, mright in
    let eqglob = f_eqglob topl ml topr mr in
    let lpre = if oil.oi_in then [eqglob;inv] else [inv] in
    let eq_params = 
      f_eqparams fl sigl.fs_params ml fr sigr.fs_params mr in
    let eq_res = f_eqres fl sigl.fs_ret ml fr sigr.fs_ret mr in
    let pre = f_ands (eq_params::lpre) in
    let post = f_ands [eq_res; eqglob; inv] in
    f_equivF pre fl fr post
  else
    let defl = EcEnv.Fun.by_xpath fl env in
    let defr = EcEnv.Fun.by_xpath fr env in
    let sigl, sigr = defl.f_sig, defr.f_sig in
    let testty = 
      List.all2 (fun v1 v2 -> EcReduction.equal_type env v1.v_type v2.v_type)
        sigl.fs_params sigr.fs_params && 
        EcReduction.equal_type env sigl.fs_ret sigr.fs_ret 
    in
    if not testty then 
      cannot_apply "call" 
        "the two functions should have the same signature";
    let ml, mr = EcFol.mleft, EcFol.mright in
    let eq_params = 
      f_eqparams fl sigl.fs_params ml fr sigr.fs_params mr in
    let eq_res = f_eqres fl sigl.fs_ret ml fr sigr.fs_ret mr in
    let pre = f_and eq_params inv in
    let post = f_and eq_res inv in
    f_equivF pre fl fr post

class rn_eqobs_in =
object
  inherit xrule "[hl] eqobs-in"
end

let rn_eqobs_in =
  RN_xtd (new rn_eqobs_in :> xrule)

let t_eqobs_inS finfo eqo inv g =
  let env, hyps, concl = get_goal_e g in
  let es = t_as_equivS concl in
  let ml, mr = fst es.es_ml, fst es.es_mr in
  (* TODO check that inv contains only global *)
  let ifvl = PV.fv env ml inv in
  let ifvr = PV.fv env mr inv in
  let sl,sr,(_,sg),eqi = 
    EcPV.eqobs_in env finfo ()
      es.es_sl es.es_sr eqo (ifvl, ifvr) in
  let post = Mpv2.to_form ml mr eqo inv in
  if not (EcReduction.is_alpha_eq hyps post es.es_po) then
    tacuerror "eqobs_in can not be apply";
  let pre = Mpv2.to_form ml mr eqi inv in
  let concl = 
    f_equivS es.es_ml es.es_mr es.es_pr sl sr pre in
  prove_goal_by (sg@[concl]) rn_eqobs_in g

type eqobs_in_rec_info = 
  | EORI_adv of Mpv2.t
  | EORI_fun of Mpv2.t
  | EORI_unknown of EcIdent.t option

type eqobs_in_log = 
  { query    : ((xpath * xpath * Mpv2.t) * (Mpv2.t * form)) list;
    forproof : eqobs_in_rec_info Mf.t 
  }

let find_eqobs_in_log log fl fr eqo = 
  let test ((fl',fr',eqo'), _) = 
    EcPath.x_equal fl fl' && EcPath.x_equal fr fr' && Mpv2.equal eqo eqo' in
  try Some (snd(List.find test log.query)) with Not_found -> None

let add_eqobs_in_log fl fr eqo (eqi,spec,info) log = 
  { query = ((fl,fr,eqo), (eqi,spec)) :: log.query;
    forproof = Mf.add spec info log.forproof }
   
let rec eqobs_inF env eqg (inv,ifvl,ifvr as inve) log fl fr eqO =
  match find_eqobs_in_log log fl fr eqO with
  | Some(eqi,spec) -> log, eqi, spec
  | None -> 
    let nfl = NormMp.norm_xpath env fl in
    let nfr = NormMp.norm_xpath env fr in
    let defl = Fun.by_xpath nfl env in
    let defr = Fun.by_xpath nfr env in
    let mk_inv_spec inv fl fr = 
      try mk_inv_spec env inv fl fr 
      with TacError _ -> raise EqObsInError in
    match defl.f_def, defr.f_def with
    | FBabs oil, FBabs oir -> 
      begin 
        let top = EcPath.m_functor nfl.EcPath.x_top in
        let log, ieqg = 
          try (* Try to infer the good invariant for oracle *)
            let eqo = Mpv2.remove_glob top eqO in
            let rec aux eqo = 
              let log, eqi = 
                List.fold_left2 
                  (fun (log,eqo) o_l o_r -> 
                    let log, eqo, _ = eqobs_inF env eqg inve log o_l o_r eqo in
                    log, eqo)
                  (log,eqo) oil.oi_calls oir.oi_calls in
              if Mpv2.subset eqi eqo then log, eqo else aux eqi in
            aux eqo 
          with EqObsInError ->
            if not (Mpv2.subset eqO eqg) then raise EqObsInError;
            log, Mpv2.remove_glob top eqg in
        let peqg = if oil.oi_in then Mpv2.add_glob env top top ieqg else ieqg in
        let inv = Mpv2.to_form mleft mright ieqg inv in
        let spec = mk_inv_spec inv fl fr in
        let log = add_eqobs_in_log fl fr eqO (peqg,spec, EORI_adv ieqg) log in
        log, peqg, spec
      end
    | FBdef funl, FBdef funr -> 
      begin 
        try
          let sigl, sigr = defl.f_sig, defr.f_sig in
          let testty = 
            List.all2 (fun v1 v2 -> 
              EcReduction.equal_type env v1.v_type v2.v_type)
              sigl.fs_params sigr.fs_params && 
              EcReduction.equal_type env sigl.fs_ret sigr.fs_ret 
          in
          if not testty then raise EqObsInError;
          let eqo' = 
            match funl.f_ret, funr.f_ret with
            | None, None -> eqO
            | Some el, Some er -> add_eqs env eqO el er 
            | _, _ -> raise EqObsInError in
          let sl, sr, (log,_), eqi =
            eqobs_in env (eqobs_inF env eqg inve) 
              log funl.f_body funr.f_body eqo' (ifvl,ifvr) in
          if sl.s_node <> [] || sr.s_node <> [] then raise EqObsInError;
          let geqi = 
            List.fold_left2 (fun eqi vl vr ->
              Mpv2.remove env (pv_loc nfl vl.v_name) (pv_loc nfr vr.v_name) eqi) 
              eqi  sigl.fs_params sigr.fs_params in
          Mpv2.check_glob geqi;
          let ml, mr = EcFol.mleft, EcFol.mright in
          let eq_params = 
            f_eqparams fl sigl.fs_params ml fr sigr.fs_params mr in
          let eq_res = f_eqres fl sigl.fs_ret ml fr sigr.fs_ret mr in
          let pre = f_and eq_params (Mpv2.to_form ml mr geqi inv) in
          let post = f_and eq_res (Mpv2.to_form ml mr eqO inv) in
          let spec = f_equivF pre fl fr post in 
          let log = add_eqobs_in_log fl fr eqO (geqi,spec,  EORI_fun eqo') log in
          log, geqi, spec
        with EqObsInError ->
          if not (Mpv2.subset eqO eqg) then raise EqObsInError;
          let inv = Mpv2.to_form mleft mright eqg inv in
          let spec = mk_inv_spec inv fl fr in
          let log  = add_eqobs_in_log fl fr eqO (eqg,spec,EORI_unknown None) log in
          log, eqg, spec
      end
    | _, _ -> raise EqObsInError 
 
class rn_hoare_true =
object
  inherit xrule "[hl] hoare-true"
end

let rn_hoare_true =
  RN_xtd (new rn_hoare_true :> xrule)

let t_hoare_true g = 
  let concl = get_concl g in
  match concl.f_node with
  | FhoareF hf when f_equal hf.hf_po f_true ->
    prove_goal_by [] rn_hoare_true g   
  | FhoareS hs when f_equal hs.hs_po f_true ->
    prove_goal_by [] rn_hoare_true g    
  | _ -> tacuerror "the conclusion should have the form hoare[_ : _ ==> true]"

  
let t_trivial = 
  let t1 = 
    t_lor [t_hoare_true;
           EcPhlExfalso.t_core_exfalso;   
           t_pr_bounded false;
           EcPhlSkip.t_skip] in
  t_or
    (t_lseq [t_try t_assumption; t_progress (t_id None); t_try t_assumption; 
             t1; t_trivial; t_fail])
    (t_id None)
  
 
(* ---SP--------------------------------------------------------------- *)
class rn_hl_sp = object inherit xrule "[hl] SP" end
let rn_hl_sp = RN_xtd (new rn_hl_sp :> xrule)

let rec sp_st side env mem pre (st : stmt) =
  let is = st.s_node in
  let f r i = sp_inst side env mem r (i.i_node) in
  List.fold_left (fun r i -> f r i) pre is
and 
  sp_inst side env mem (pre : form) (inst : instr_node) : form=
  match inst with
  | Sasgn (LvVar(lf,lty) as lvL, muL) ->
    let fl   = f_pvar lf lty side in
    let x_id = if (EcIdent.id_equal mleft side ) then EcIdent.create (symbol_of_lv lvL ^ "L")
               else  EcIdent.create (symbol_of_lv lvL ^ "R")in
    let x    = f_local x_id lty in
    let muL  = EcFol.form_of_expr (EcMemory.memory mem) muL in
    let muL' = (subst_form_lv env (EcMemory.memory mem) lvL x muL) in
    let eq p q = mk_form (Fapp (fop_eq lty, p :: q :: [])) tbool in
    let fvl  = EcPV.PV.fv env (EcMemory.memory mem) pre in (* FV(pre) *)
    let fvm  = EcPV.PV.fv env (EcMemory.memory mem) muL in (* FV(e) *)
    if (EcPV.PV.mem_pv env lf fvl) || (EcPV.PV.mem_pv env lf fvm) then
      let pr = subst_form_lv env (EcMemory.memory mem) lvL x pre in
      f_exists [(x_id, GTty lty)]  (f_and_simpl (eq fl muL') pr)
    else
      f_and_simpl (eq fl muL) pre 
  | Sif (e,st1,st2) ->
    let b = EcFol.form_of_expr (EcMemory.memory mem) e in (* condition *)
    let pb = f_and_simpl pre b in
    let pnb = f_and_simpl pre (f_not b) in
    let sp1 = sp_st side env mem pb st1 in
    let sp2 = sp_st side env mem pnb st2 in
      f_or sp1 sp2
  | _ -> cannot_apply "sp" "sp only works with single asgn or if"


let t_sp_aux side g =
  let (env, _, concl) = get_goal_e g in
  let err ()  = cannot_apply "sp" "with an empty goal" in
  let stmt, m, menv, pre, prove_goal = 
    try 
      let es = t_as_equivS concl in
      if side then 
          es.es_sl,mleft, es.es_ml, es.es_pr, 
           fun pr st -> 
             let wes = f_equivS_r {es with es_sl=st; es_pr=pr} in
             t_on_last t_simplify_nodelta (prove_goal_by [wes] rn_hl_sp g)
      else es.es_sr, mright, es.es_mr, es.es_pr, 
        fun pr st -> 
          let wes = f_equivS_r {es with es_sr=st; es_pr=pr} in
          t_on_last t_simplify_nodelta (prove_goal_by [wes] rn_hl_sp g)
    with EcBaseLogic.TacError _ ->
      try
        let hs = t_as_hoareS concl in
        hs.hs_s, mhr, hs.hs_m, hs.hs_pr, 
        fun pr st -> 
          let wes = f_hoareS_r {hs with hs_s=st; hs_pr=pr} in
          t_on_last t_simplify_nodelta (prove_goal_by [wes] rn_hl_sp g)
      with EcBaseLogic.TacError _ ->
        try
          let bhs = t_as_bdHoareS concl in
          bhs.bhs_s, mhr, bhs.bhs_m, bhs.bhs_pr, 
          fun pr st -> 
            let wes = f_bdHoareS_r {bhs with bhs_s=st; bhs_pr=pr} in
            t_on_last t_simplify_nodelta (prove_goal_by [wes] rn_hl_sp g)
        with EcBaseLogic.TacError _ ->
          tacuerror "Unexpected goal"
  in
  let pr,stmt =
    let (l, ls) =  match stmt.s_node with [] -> err () | i::s -> (i, EcModules.stmt s) in
    let pr  = sp_inst m env menv pre (l.i_node) in
    pr,ls
  in
  prove_goal pr stmt


let t_sp side g =
  let sp s = t_repeat (t_sp_aux s) in
  match side with
  | None   ->
    t_on_last (sp false) (sp true g)
  | Some s ->
    t_repeat (t_sp_aux s) g
