(*
 * cond_monad.ml
 *
 * bintrans
 *
 * Copyright (C) 2004 Mark Probst
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 *)

open List

open Monad
open Expr

exception No_value
exception No_conditions
exception No_failure_condition

(* A condition monad can be a success, in which case we store the value and a
list of conditions that made it a sucess.

It can also be a failure with a reason, in which case we store all the
conditions that made it a success until the point of failure and the condition
that made it a failure (which folds to false).

Finally, it can also be an unconditional failure. *)

type 'a condition_monad =
    CMSuccess of 'a * (expr list)
  | CMFailureWithReason of (expr list) * expr
  | CMFailure

let cm_return expr = CMSuccess (expr, [])
let cm_fail = CMFailure

let cm_bind value fn =
  match value with
    CMSuccess (value_expr, value_conds) ->
      (match fn value_expr with
	CMSuccess (result_expr, result_conds) -> CMSuccess (result_expr, result_conds @ value_conds)
      | CMFailureWithReason (result_conds, fcond) -> CMFailureWithReason (result_conds @ value_conds, fcond)
      | CMFailure -> CMFailure)
  | CMFailureWithReason (conds, fcond) -> CMFailureWithReason (conds, fcond)
  | CMFailure -> CMFailure

(* let cm_bind2 = make_bind2 cm_bind *)
(* let cm_bind3 = make_bind3 cm_bind *)

let cm_if fields condition consequent alternative =
  let ccond = cfold_expr fields condition
  in if is_const ccond then
    match ccond with
      ConditionConst true ->
	(match consequent () with
	  CMSuccess (expr, conds) -> CMSuccess (expr, condition :: conds)
	| CMFailureWithReason (conds, fcond) -> CMFailureWithReason (condition :: conds, fcond)
	| CMFailure -> CMFailure)
    | ConditionConst false ->
	(match alternative () with
	  CMSuccess (expr, conds) -> CMSuccess (expr, (Unary (ConditionNeg, condition)) :: conds)
	| CMFailureWithReason (conds, fcond) -> CMFailureWithReason ((Unary (ConditionNeg, condition)) :: conds, fcond)
	| CMFailure -> CMFailure)
    | _ -> raise Wrong_type
  else
    raise Expression_not_const

let cm_when fields condition consequent =
  let ccond = cfold_expr fields condition
  in if is_const ccond then
    match ccond with
      ConditionConst true ->
	(match consequent () with
	  CMSuccess (expr, conds) -> CMSuccess (expr, condition :: conds)
	| CMFailureWithReason (conds, fcond) -> CMFailureWithReason (condition :: conds, fcond)
	| CMFailure -> CMFailure)
    | ConditionConst false ->
	CMFailureWithReason ([], condition)
    | _ -> raise Wrong_type
  else
    raise Expression_not_const

let cm_if_success condition_cm consequent_fn alternative =
  match condition_cm with
    CMSuccess (expr, conds) -> cm_bind condition_cm consequent_fn
  | CMFailureWithReason (conds, fcond) ->
      (match alternative () with
	CMSuccess (alt_expr, alt_conds) ->
	  CMSuccess (alt_expr, (Unary (ConditionNeg, fcond)) :: (alt_conds @ conds))
      | CMFailureWithReason (alt_conds, alt_fcond) ->
	  CMFailureWithReason ((Unary (ConditionNeg, fcond)) :: (alt_conds @ conds), alt_fcond)
      | CMFailure -> CMFailure)
  | CMFailure -> alternative ()

let cm_successful m =
  match m with
    CMSuccess _ -> true
  | CMFailureWithReason _ | CMFailure -> false

let cm_value m =
  match m with
    CMSuccess (value, _) -> value
  | CMFailureWithReason _ | CMFailure -> raise No_value

let cm_conditions m =
  match m with
    CMSuccess (_, conds) -> conds
  | CMFailureWithReason (conds, _) -> conds
  | CMFailure -> raise No_conditions

let cm_failure_condition m =
  match m with
    CMFailureWithReason (_, fcond) -> fcond
  | CMSuccess _ | CMFailure -> raise No_failure_condition

let cm_yield m =
  match m with
    CMSuccess (value, conds) -> (value, conds)
  | CMFailureWithReason _ | CMFailure -> raise No_value

(*** stmt_or_expr cond monads ***)

let expr_cond_monad_to_stmt_or_expr_cond_monad m =
  match m with
      CMSuccess (value, conds) -> CMSuccess (Expr value, conds)
    | CMFailureWithReason (conds, fcond) -> CMFailureWithReason (conds, fcond)
    | CMFailure -> CMFailure

let stmt_or_expr_cond_monad_to_stmt_cond_monad m =
  match m with
      CMSuccess (value, conds) -> CMSuccess (get_stmt value, conds)
    | CMFailureWithReason (conds, fcond) -> CMFailureWithReason (conds, fcond)
    | CMFailure -> CMFailure

let apply_to_stmt_subs_with_cond_monad modify stmt =
  stmt_or_expr_cond_monad_to_stmt_cond_monad
    (apply_to_stmt_subs_with_monad cm_return cm_bind
       (fun expr -> expr_cond_monad_to_stmt_or_expr_cond_monad (modify expr))
       stmt)
