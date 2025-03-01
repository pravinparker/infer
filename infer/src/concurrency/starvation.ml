(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd
module F = Format
module L = Logging
module MF = MarkupFormatter

let pname_pp = MF.wrap_monospaced Typ.Procname.pp

let debug fmt = L.(debug Analysis Verbose fmt)

let attrs_of_pname = Summary.OnDisk.proc_resolve_attributes

let is_ui_thread_model pn =
  ConcurrencyModels.(match get_thread pn with MainThread -> true | _ -> false)


let is_nonblocking tenv proc_desc =
  let proc_attributes = Procdesc.get_attributes proc_desc in
  let is_method_suppressed =
    Annotations.pdesc_has_return_annot proc_desc Annotations.ia_is_nonblocking
  in
  let is_class_suppressed =
    PatternMatch.get_this_type proc_attributes
    |> Option.bind ~f:(PatternMatch.type_get_annotation tenv)
    |> Option.exists ~f:Annotations.ia_is_nonblocking
  in
  is_method_suppressed || is_class_suppressed


module Payload = SummaryPayload.Make (struct
  type t = StarvationDomain.summary

  let field = Payloads.Fields.starvation
end)

(* using an indentifier for a class object, create an access path representing that lock;
   this is for synchronizing on Java class objects only *)
let lock_of_class =
  let typ = Typ.(mk (Tstruct Name.Java.java_lang_class)) in
  let typ' = Typ.(mk (Tptr (typ, Pk_pointer))) in
  fun class_id ->
    let ident = Ident.create_normal class_id 0 in
    AccessPath.of_id ident typ'


module TransferFunctions (CFG : ProcCfg.S) = struct
  module CFG = CFG
  module Domain = StarvationDomain

  type extras = FormalMap.t

  let exec_instr (astate : Domain.t) {ProcData.summary; tenv; extras} _ (instr : HilInstr.t) =
    let open ConcurrencyModels in
    let open StarvationModels in
    let log_parse_error error pname actuals =
      L.debug Analysis Verbose "%s pname:%a actuals:%a@." error Typ.Procname.pp pname
        (PrettyPrintable.pp_collection ~pp_item:HilExp.pp)
        actuals
    in
    let get_lock_path = function
      | HilExp.AccessExpression access_exp -> (
        match HilExp.AccessExpression.to_access_path access_exp with
        | (((Var.ProgramVar pvar, _) as base), _) as path
          when FormalMap.is_formal base extras || Pvar.is_global pvar ->
            Some (AccessPath.inner_class_normalize path)
        | _ ->
            (* ignore paths on local or logical variables *)
            None )
      | HilExp.Constant (Const.Cclass class_id) ->
          (* this is a synchronized/lock(CLASSNAME.class) construct *)
          Some (lock_of_class class_id)
      | _ ->
          None
    in
    let procname = Summary.get_proc_name summary in
    let is_java = Typ.Procname.is_java procname in
    let do_lock locks loc astate =
      List.filter_map ~f:get_lock_path locks |> Domain.acquire tenv astate ~procname ~loc
    in
    let do_unlock locks astate = List.filter_map ~f:get_lock_path locks |> Domain.release astate in
    let do_call callee loc astate =
      Payload.read ~caller_summary:summary ~callee_pname:callee
      |> Option.value_map ~default:astate ~f:(fun callee_summary ->
             Domain.integrate_summary tenv ~caller_summary:astate ~callee_summary ~callee ~loc )
    in
    match instr with
    | Assign _ | Assume _ | Call (_, Indirect _, _, _, _) | Metadata _ ->
        astate
    | Call (_, Direct callee, actuals, _, _) when should_skip_analysis tenv callee actuals ->
        astate
    | Call (_, Direct callee, actuals, _, loc) -> (
      match get_lock_effect callee actuals with
      | Lock locks ->
          do_lock locks loc astate
      | GuardLock guard ->
          Domain.lock_guard tenv astate guard ~procname ~loc
      | GuardConstruct {guard; lock; acquire_now} -> (
        match get_lock_path lock with
        | Some lock_path ->
            Domain.add_guard tenv astate guard lock_path ~acquire_now ~procname ~loc
        | None ->
            log_parse_error "Couldn't parse lock in guard constructor" callee actuals ;
            astate )
      | Unlock locks ->
          do_unlock locks astate
      | GuardUnlock guard ->
          Domain.unlock_guard astate guard
      | GuardDestroy guard ->
          Domain.remove_guard astate guard
      | LockedIfTrue _ | GuardLockedIfTrue _ ->
          astate
      | NoEffect when is_synchronized_library_call tenv callee ->
          (* model a synchronized call without visible internal behaviour *)
          let locks = List.hd actuals |> Option.to_list in
          do_lock locks loc astate |> do_unlock locks
      | NoEffect when is_java && is_ui_thread_model callee ->
          Domain.set_on_ui_thread astate ~loc
            (Domain.UIThreadElement.CallsModeled {proc_name= procname; callee})
      | NoEffect when is_java && is_strict_mode_violation tenv callee actuals ->
          Domain.strict_mode_call ~callee ~loc astate
      | NoEffect when is_java -> (
        match may_block tenv callee actuals with
        | Some sev ->
            Domain.blocking_call ~callee sev ~loc astate
        | None ->
            do_call callee loc astate )
      | NoEffect ->
          (* in C++/Obj C we only care about deadlocks, not starvation errors *)
          do_call callee loc astate )


  let pp_session_name _node fmt = F.pp_print_string fmt "starvation"
end

module Analyzer = LowerHil.MakeAbstractInterpreter (TransferFunctions (ProcCfg.Normal))

let analyze_procedure {Callbacks.exe_env; summary} =
  let proc_desc = Summary.get_proc_desc summary in
  let procname = Procdesc.get_proc_name proc_desc in
  let tenv = Exe_env.get_tenv exe_env procname in
  if StarvationModels.should_skip_analysis tenv procname [] then summary
  else
    let formals = FormalMap.make proc_desc in
    let proc_data = ProcData.make summary tenv formals in
    let loc = Procdesc.get_loc proc_desc in
    let initial =
      if not (Procdesc.is_java_synchronized proc_desc) then StarvationDomain.bottom
      else
        let lock =
          match procname with
          | Typ.Procname.Java java_pname when Typ.Procname.Java.is_static java_pname ->
              (* this is crafted so as to match synchronized(CLASSNAME.class) constructs *)
              Typ.Procname.Java.get_class_type_name java_pname
              |> Typ.Name.name |> Ident.string_to_name |> lock_of_class |> Option.some
          | _ ->
              FormalMap.get_formal_base 0 formals |> Option.map ~f:(fun base -> (base, []))
        in
        StarvationDomain.acquire tenv StarvationDomain.bottom ~procname ~loc (Option.to_list lock)
    in
    let initial =
      StarvationModels.get_uithread_explanation ~attrs_of_pname tenv procname
      |> Option.value_map ~default:initial ~f:(StarvationDomain.set_on_ui_thread initial ~loc)
    in
    let filter_blocks =
      if is_nonblocking tenv proc_desc then StarvationDomain.filter_blocking_calls else Fn.id
    in
    Analyzer.compute_post proc_data ~initial
    |> Option.map ~f:filter_blocks
    |> Option.value_map ~default:summary ~f:(fun astate -> Payload.update_summary astate summary)


(** per-procedure report map, which takes care of deduplication *)
module ReportMap : sig
  type t

  val empty : t

  type report_add_t = Typ.Procname.t -> Location.t -> Errlog.loc_trace -> string -> t -> t

  val add_deadlock : report_add_t

  val add_starvation : StarvationModels.severity -> report_add_t

  val add_strict_mode_violation : report_add_t

  val add_lockless_violation : report_add_t

  val log : IssueLog.t -> Tenv.t -> Procdesc.t -> t -> IssueLog.t
end = struct
  type problem =
    | Starvation of StarvationModels.severity
    | Deadlock of int
    | StrictModeViolation of int
    | LocklessViolation of int

  type report_t = {problem: problem; pname: Typ.Procname.t; ltr: Errlog.loc_trace; message: string}

  module LocMap = PrettyPrintable.MakePPMap (Location)

  type t = report_t list LocMap.t

  type report_add_t = Typ.Procname.t -> Location.t -> Errlog.loc_trace -> string -> t -> t

  let empty : t = LocMap.empty

  let add loc report map =
    let reports = try LocMap.find loc map with Caml.Not_found -> [] in
    let new_reports = report :: reports in
    LocMap.add loc new_reports map


  let add_deadlock pname loc ltr message (map : t) =
    let report = {problem= Deadlock (-List.length ltr); pname; ltr; message} in
    add loc report map


  let add_starvation sev pname loc ltr message map =
    let report = {pname; problem= Starvation sev; ltr; message} in
    add loc report map


  let add_strict_mode_violation pname loc ltr message (map : t) =
    let report = {problem= StrictModeViolation (-List.length ltr); pname; ltr; message} in
    add loc report map


  let add_lockless_violation pname loc ltr message (map : t) =
    let report = {problem= LocklessViolation (-List.length ltr); pname; ltr; message} in
    add loc report map


  let log start_issue_log tenv pdesc map =
    let log_report ~issue_log loc {problem; pname; ltr; message} =
      let issue_type =
        match problem with
        | Deadlock _ ->
            IssueType.deadlock
        | Starvation _ ->
            IssueType.starvation
        | StrictModeViolation _ ->
            IssueType.strict_mode_violation
        | LocklessViolation _ ->
            IssueType.lockless_violation
      in
      if Reporting.is_suppressed tenv pdesc issue_type then issue_log
      else
        Reporting.log_issue_external ~issue_log pname Exceptions.Error ~loc ~ltr issue_type message
    in
    let mk_deduped_report ({message} as report) =
      { report with
        message= Printf.sprintf "%s Additional report(s) on the same line were suppressed." message
      }
    in
    let log_reports compare loc reports issue_log =
      if Config.deduplicate then
        match reports with
        | [] ->
            issue_log
        | [(_, report)] ->
            log_report ~issue_log loc report
        | reports ->
            List.max_elt ~compare reports
            |> Option.fold ~init:issue_log ~f:(fun acc (_, rep) ->
                   mk_deduped_report rep |> log_report ~issue_log:acc loc )
      else
        List.fold reports ~init:issue_log ~f:(fun acc (_, rep) -> log_report ~issue_log:acc loc rep)
    in
    let filter_map_deadlock = function {problem= Deadlock l} as r -> Some (l, r) | _ -> None in
    let filter_map_starvation = function
      | {problem= Starvation s} as r ->
          Some (s, r)
      | _ ->
          None
    in
    let filter_map_strict_mode_violation = function
      | {problem= StrictModeViolation l} as r ->
          Some (l, r)
      | _ ->
          None
    in
    let filter_map_lockless_violation = function
      | {problem= LocklessViolation l} as r ->
          Some (l, r)
      | _ ->
          None
    in
    let compare_reports weight_compare (w, r) (w', r') =
      match weight_compare w w' with 0 -> String.compare r.message r'.message | result -> result
    in
    let log_location loc problems issue_log =
      let deadlocks = List.filter_map problems ~f:filter_map_deadlock in
      let starvations = List.filter_map problems ~f:filter_map_starvation in
      let strict_mode_violations = List.filter_map problems ~f:filter_map_strict_mode_violation in
      let lockless_violations = List.filter_map problems ~f:filter_map_lockless_violation in
      log_reports (compare_reports Int.compare) loc deadlocks issue_log
      |> log_reports (compare_reports Int.compare) loc lockless_violations
      |> log_reports (compare_reports StarvationModels.compare_severity) loc starvations
      |> log_reports (compare_reports Int.compare) loc strict_mode_violations
    in
    LocMap.fold log_location map start_issue_log
end

let should_report_deadlock_on_current_proc current_elem endpoint_elem =
  (not Config.deduplicate)
  ||
  let open StarvationDomain in
  match (endpoint_elem.CriticalPair.elem.event, current_elem.CriticalPair.elem.event) with
  | _, (MayBlock _ | StrictModeCall _) | (MayBlock _ | StrictModeCall _), _ ->
      (* should never happen *)
      L.die InternalError "Deadlock cannot occur without two lock events: %a" CriticalPair.pp
        current_elem
  | LockAcquire ((Var.LogicalVar _, _), []), _ ->
      (* first elem is a class object (see [lock_of_class]), so always report because the
         reverse ordering on the events will not occur -- FIXME WHY? *)
      true
  | LockAcquire ((Var.LogicalVar _, _), _ :: _), _ | _, LockAcquire ((Var.LogicalVar _, _), _) ->
      (* first elem has an ident root, but has a non-empty access path, which means we are
         not filtering out local variables (see [exec_instr]), or,
         second elem has an ident root, which should not happen if we are filtering locals *)
      L.die InternalError "Deadlock cannot occur on these logical variables: %a @." CriticalPair.pp
        current_elem
  | LockAcquire ((_, typ1), _), LockAcquire ((_, typ2), _) ->
      (* use string comparison on types as a stable order to decide whether to report a deadlock *)
      let c = String.compare (Typ.to_string typ1) (Typ.to_string typ2) in
      c < 0
      || Int.equal 0 c
         && (* same class, so choose depending on location *)
            Location.compare current_elem.CriticalPair.loc endpoint_elem.CriticalPair.loc < 0


let should_report pdesc =
  Procdesc.get_access pdesc <> PredSymb.Private
  &&
  match Procdesc.get_proc_name pdesc with
  | Typ.Procname.Java java_pname ->
      (not (Typ.Procname.Java.is_autogen_method java_pname))
      && not (Typ.Procname.Java.is_class_initializer java_pname)
  | Typ.Procname.ObjC_Cpp _ ->
      true
  | _ ->
      false


let fold_reportable_summaries (tenv, current_summary) clazz ~init ~f =
  let methods =
    Tenv.lookup tenv clazz
    |> Option.value_map ~default:[] ~f:(fun tstruct -> tstruct.Typ.Struct.methods)
  in
  let f acc mthd =
    Ondemand.get_proc_desc mthd
    |> Option.value_map ~default:acc ~f:(fun other_pdesc ->
           if should_report other_pdesc then
             Payload.read ~caller_summary:current_summary ~callee_pname:mthd
             |> Option.map ~f:(fun payload -> (mthd, payload))
             |> Option.fold ~init:acc ~f
           else acc )
  in
  List.fold methods ~init ~f


let report_lockless_violations (tenv, summary) StarvationDomain.{critical_pairs} report_map =
  let open StarvationDomain in
  (* this is inneficient as it climbs the hierarchy potentially twice *)
  let is_annotated_lockless tenv pname =
    let check annot = Annotations.(ia_ends_with annot lockless) in
    let check_attributes pname =
      PatternMatch.check_class_attributes check tenv pname
      || Annotations.pname_has_return_annot pname ~attrs_of_pname check
    in
    PatternMatch.override_exists check_attributes tenv pname
  in
  let pname = Summary.get_proc_name summary in
  if not (is_annotated_lockless tenv pname) then report_map
  else
    let report_violation ({elem= {event}} as critical_pair : CriticalPair.t) report_map =
      match event with
      | LockAcquire _ ->
          let error_message =
            Format.asprintf "Method %a is annotated %s but%a." pname_pp pname
              (MF.monospaced_to_string Annotations.lockless)
              Event.describe event
          in
          let loc = CriticalPair.get_earliest_lock_or_call_loc ~procname:pname critical_pair in
          let ltr = CriticalPair.make_trace pname critical_pair in
          ReportMap.add_lockless_violation pname loc ltr error_message report_map
      | _ ->
          report_map
    in
    CriticalPairs.fold report_violation critical_pairs report_map


(*  Note about how many times we report a deadlock: normally twice, at each trace starting point.
    Due to the fact we look for deadlocks in the summaries of the class at the root of a path,
    this will fail when (a) the lock is of class type (ie as used in static sync methods), because
    then the root is an identifier of type java.lang.Class and (b) when the lock belongs to an
    inner class but this is no longer obvious in the path, because of nested-class path normalisation.
    The net effect of the above issues is that we will only see these locks in conflicting pairs
    once, as opposed to twice with all other deadlock pairs. *)
let report_deadlocks env StarvationDomain.{critical_pairs; ui} report_map' =
  let open StarvationDomain in
  let _, current_summary = env in
  let current_pname = Summary.get_proc_name current_summary in
  let report_endpoint_elem current_elem endpoint_pname elem report_map =
    if
      not
        ( CriticalPair.may_deadlock current_elem elem
        && should_report_deadlock_on_current_proc current_elem elem )
    then report_map
    else
      let () =
        debug "Possible deadlock:@.%a@.%a@." CriticalPair.pp current_elem CriticalPair.pp elem
      in
      match (current_elem.CriticalPair.elem.event, elem.CriticalPair.elem.event) with
      | LockAcquire lock1, LockAcquire lock2 ->
          let error_message =
            Format.asprintf
              "Potential deadlock. %a (Trace 1) and %a (Trace 2) acquire locks %a and %a in \
               reverse orders."
              pname_pp current_pname pname_pp endpoint_pname Lock.describe lock1 Lock.describe
              lock2
          in
          let first_trace =
            CriticalPair.make_trace ~header:"[Trace 1] " current_pname current_elem
          in
          let second_trace = CriticalPair.make_trace ~header:"[Trace 2] " endpoint_pname elem in
          let ltr = first_trace @ second_trace in
          let loc =
            CriticalPair.get_earliest_lock_or_call_loc ~procname:current_pname current_elem
          in
          ReportMap.add_deadlock current_pname loc ltr error_message report_map
      | _, _ ->
          report_map
  in
  let report_on_current_elem elem report_map =
    match elem.CriticalPair.elem.event with
    | MayBlock _ | StrictModeCall _ ->
        report_map
    | LockAcquire endpoint_lock
      when Acquisitions.lock_is_held endpoint_lock elem.CriticalPair.elem.acquisitions ->
        let error_message =
          Format.asprintf "Potential self deadlock. %a%a twice." pname_pp current_pname
            Lock.pp_locks endpoint_lock
        in
        let ltr = CriticalPair.make_trace ~header:"In method " current_pname elem in
        let loc = CriticalPair.get_earliest_lock_or_call_loc ~procname:current_pname elem in
        ReportMap.add_deadlock current_pname loc ltr error_message report_map
    | LockAcquire endpoint_lock ->
        Lock.owner_class endpoint_lock
        |> Option.value_map ~default:report_map ~f:(fun endpoint_class ->
               (* get the class of the root variable of the lock in the endpoint elem
                   and retrieve all the summaries of the methods of that class *)
               (* for each summary related to the endpoint, analyse and report on its pairs *)
               fold_reportable_summaries env endpoint_class ~init:report_map
                 ~f:(fun acc
                    (endpoint_pname, {critical_pairs= endp_critical_pairs; ui= endp_ui})
                    ->
                   if UIThreadDomain.is_bottom ui || UIThreadDomain.is_bottom endp_ui then
                     CriticalPairs.fold
                       (report_endpoint_elem elem endpoint_pname)
                       endp_critical_pairs acc
                   else acc ) )
  in
  CriticalPairs.fold report_on_current_elem critical_pairs report_map'


let report_starvation env {StarvationDomain.critical_pairs; ui} report_map' =
  let open StarvationDomain in
  let _, current_summary = env in
  let current_pname = Summary.get_proc_name current_summary in
  let report_remote_block ui_explain event current_lock endpoint_pname endpoint_elem report_map =
    let acquisitions = endpoint_elem.CriticalPair.elem.acquisitions in
    match endpoint_elem.CriticalPair.elem.event with
    | MayBlock (block_descr, sev) when Acquisitions.lock_is_held current_lock acquisitions ->
        let error_message =
          Format.asprintf
            "Method %a runs on UI thread (because %a) and%a, which may be held by another thread \
             which %s."
            pname_pp current_pname UIThreadExplanationDomain.pp ui_explain Lock.pp_locks
            current_lock block_descr
        in
        let first_trace = CriticalPair.make_trace ~header:"[Trace 1] " current_pname event in
        let second_trace =
          CriticalPair.make_trace ~header:"[Trace 2] " endpoint_pname endpoint_elem
        in
        let ui_trace =
          UIThreadExplanationDomain.make_trace ~header:"[Trace 1 on UI thread] " current_pname
            ui_explain
        in
        let ltr = first_trace @ second_trace @ ui_trace in
        let loc = CriticalPair.get_earliest_lock_or_call_loc ~procname:current_pname event in
        ReportMap.add_starvation sev current_pname loc ltr error_message report_map
    | _ ->
        report_map
  in
  let report_on_current_elem ui_explain (critical_pair : CriticalPair.t) report_map =
    let event = critical_pair.elem.event in
    match event with
    | MayBlock (_, sev) ->
        let error_message =
          Format.asprintf "Method %a runs on UI thread (because %a), and may block; %a." pname_pp
            current_pname UIThreadExplanationDomain.pp ui_explain Event.describe event
        in
        let loc = CriticalPair.get_loc critical_pair in
        let trace =
          CriticalPair.make_trace ~include_acquisitions:false current_pname critical_pair
        in
        let ui_trace =
          UIThreadExplanationDomain.make_trace ~header:"[Trace on UI thread] " current_pname
            ui_explain
        in
        let ltr = trace @ ui_trace in
        ReportMap.add_starvation sev current_pname loc ltr error_message report_map
    | StrictModeCall _ ->
        let error_message =
          Format.asprintf
            "Method %a runs on UI thread (because %a), and may violate Strict Mode; %a." pname_pp
            current_pname UIThreadExplanationDomain.pp ui_explain Event.describe event
        in
        let loc = CriticalPair.get_loc critical_pair in
        let trace =
          CriticalPair.make_trace ~include_acquisitions:false current_pname critical_pair
        in
        let ui_trace =
          UIThreadExplanationDomain.make_trace ~header:"[Trace on UI thread] " current_pname
            ui_explain
        in
        let ltr = trace @ ui_trace in
        ReportMap.add_strict_mode_violation current_pname loc ltr error_message report_map
    | LockAcquire endpoint_lock ->
        Lock.owner_class endpoint_lock
        |> Option.value_map ~default:report_map ~f:(fun endpoint_class ->
               (* get the class of the root variable of the lock in the endpoint elem
                 and retrieve all the summaries of the methods of that class *)
               (* for each summary related to the endpoint, analyse and report on its pairs *)
               fold_reportable_summaries env endpoint_class ~init:report_map
                 ~f:(fun acc (endpoint_pname, {critical_pairs; ui}) ->
                   (* skip methods on ui thread, as they cannot run in parallel to us *)
                   if UIThreadDomain.is_bottom ui then
                     CriticalPairs.fold
                       (report_remote_block ui_explain critical_pair endpoint_lock endpoint_pname)
                       critical_pairs acc
                   else acc ) )
  in
  (* do not report starvation/strict mode warnings on constructors, keep that for callers *)
  if Typ.Procname.is_constructor current_pname then report_map'
  else
    match ui with
    | AbstractDomain.Types.Bottom ->
        report_map'
    | AbstractDomain.Types.NonBottom ui_explain ->
        CriticalPairs.fold (report_on_current_elem ui_explain) critical_pairs report_map'


let reporting {Callbacks.procedures; source_file} =
  let report_procedure issue_log ((tenv, summary) as env) =
    let proc_desc = Summary.get_proc_desc summary in
    if should_report proc_desc then
      Payload.read_toplevel_procedure (Procdesc.get_proc_name proc_desc)
      |> Option.value_map ~default:issue_log ~f:(fun summary ->
             report_deadlocks env summary ReportMap.empty
             |> report_lockless_violations env summary
             |> report_starvation env summary
             |> ReportMap.log issue_log tenv proc_desc )
    else issue_log
  in
  List.fold procedures ~init:IssueLog.empty ~f:report_procedure
  |> IssueLog.store ~dir:Config.starvation_issues_dir_name ~file:source_file
