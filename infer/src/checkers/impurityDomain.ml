(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format

type trace =
  | WrittenTo of unit PulseDomain.InterprocAction.t
  | Invalid of PulseDomain.Invalidation.t PulseDomain.Trace.t
[@@deriving compare]

module ModifiedVar = struct
  type nonempty_action_type = trace * trace list [@@deriving compare]

  type t = {var: Var.t; trace_list: nonempty_action_type} [@@deriving compare]

  let pp fmt {var} = F.fprintf fmt "@\n %a @\n" Var.pp var
end

module ModifiedVarSet = AbstractDomain.FiniteSet (ModifiedVar)

type t = {modified_params: ModifiedVarSet.t; modified_globals: ModifiedVarSet.t}

let is_pure {modified_globals; modified_params} =
  ModifiedVarSet.is_empty modified_globals && ModifiedVarSet.is_empty modified_params


let pure = {modified_params= ModifiedVarSet.empty; modified_globals= ModifiedVarSet.empty}

let join astate1 astate2 =
  if phys_equal astate1 astate2 then astate1
  else
    let {modified_globals= mg1; modified_params= mp1} = astate1 in
    let {modified_globals= mg2; modified_params= mp2} = astate2 in
    PhysEqual.optim2
      ~res:
        { modified_globals= ModifiedVarSet.join mg1 mg2
        ; modified_params= ModifiedVarSet.join mp1 mp2 }
      astate1 astate2


type param_source = Formal | Global

let pp_param_source fmt = function
  | Formal ->
      F.pp_print_string fmt "parameter"
  | Global ->
      F.pp_print_string fmt "global variable"


let add_to_errlog ~nesting param_source ModifiedVar.{var; trace_list} errlog =
  let rec aux ~nesting rev_errlog action =
    match action with
    | WrittenTo (PulseDomain.InterprocAction.Immediate {location}) ->
        let rev_errlog =
          Errlog.make_trace_element nesting location
            (F.asprintf "%a '%a' is modified at %a" pp_param_source param_source Var.pp var
               Location.pp location)
            []
          :: rev_errlog
        in
        List.rev_append rev_errlog errlog
    | WrittenTo (PulseDomain.InterprocAction.ViaCall {action; f; location}) ->
        aux ~nesting:(nesting + 1)
          ( Errlog.make_trace_element nesting location
              (F.asprintf "%a '%a' is modified when calling %a at %a" pp_param_source param_source
                 Var.pp var PulseDomain.CallEvent.describe f Location.pp location)
              []
          :: rev_errlog )
          (WrittenTo action)
    | Invalid trace ->
        PulseDomain.Trace.add_to_errlog
          ~header:(F.asprintf "%a '%a'" pp_param_source param_source Var.pp var)
          (fun f invalidation ->
            F.fprintf f "%a here" PulseDomain.Invalidation.describe invalidation )
          trace rev_errlog
  in
  let first_trace, rest = trace_list in
  List.fold_left rest ~init:(aux ~nesting [] first_trace) ~f:(aux ~nesting)
