------------------------------ MODULE Spec ------------------------------
(*************************************************************************)
(* Minimal model of agent-screen-lite virtual-display lifecycle.         *)
(*                                                                       *)
(* Product map (README tools):                                           *)
(*   screen_create → (screen_move_app | screen_capture)* → screen_destroy*)
(*   Named virtual displays; cannot capture/move after destroy;          *)
(*   cannot double-destroy; cannot move to an unknown id.                *)
(*************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
  DisplayIds,   \* candidate names/ids, e.g. {"d1","d2"}
  MaxLive       \* max concurrent live displays (Nat)

ASSUME DisplayIds # {} /\ MaxLive \in Nat /\ MaxLive >= 1

VARIABLES
  live,       \* SUBSET DisplayIds — created and not yet destroyed
  lastAction  \* for readability in traces: <<"ok"|"refused", op, id>>

Ops == {"create","move_app","capture","destroy"}
Vars == <<live, lastAction>>

TypeOK ==
  /\ live \subseteq DisplayIds
  /\ lastAction \in
       ( {"ok","refused"} \X Ops \X (DisplayIds \union {"-"}) )

Init ==
  /\ live = {}
  /\ lastAction = <<"ok","create","-">>

Create(id) ==
  /\ id \notin live
  /\ Cardinality(live) < MaxLive
  /\ live' = live \union {id}
  /\ lastAction' = <<"ok","create",id>>

\* Refuse create if already live or at capacity.
RefuseCreate(id) ==
  /\ id \in DisplayIds
  /\ \/ id \in live
     \/ Cardinality(live) >= MaxLive
  /\ lastAction' = <<"refused","create",id>>
  /\ UNCHANGED live

MoveApp(id) ==
  /\ id \in live
  /\ lastAction' = <<"ok","move_app",id>>
  /\ UNCHANGED live

Capture(id) ==
  /\ id \in live
  /\ lastAction' = <<"ok","capture",id>>
  /\ UNCHANGED live

\* Cannot move/capture unknown or destroyed id.
RefuseMoveOrCapture(id, op) ==
  /\ op \in {"move_app","capture"}
  /\ id \in DisplayIds
  /\ id \notin live
  /\ lastAction' = <<"refused",op,id>>
  /\ UNCHANGED live

Destroy(id) ==
  /\ id \in live
  /\ live' = live \ {id}
  /\ lastAction' = <<"ok","destroy",id>>

\* Cannot double-destroy / destroy unknown.
RefuseDestroy(id) ==
  /\ id \in DisplayIds
  /\ id \notin live
  /\ lastAction' = <<"refused","destroy",id>>
  /\ UNCHANGED live

Next ==
  \/ \E id \in DisplayIds : Create(id)
  \/ \E id \in DisplayIds : RefuseCreate(id)
  \/ \E id \in DisplayIds : MoveApp(id)
  \/ \E id \in DisplayIds : Capture(id)
  \/ \E id \in DisplayIds, op \in {"move_app","capture"} :
        RefuseMoveOrCapture(id, op)
  \/ \E id \in DisplayIds : Destroy(id)
  \/ \E id \in DisplayIds : RefuseDestroy(id)

Spec == Init /\ [][Next]_Vars

(*************************************************************************)
(* Invariants                                                             *)
(*************************************************************************)

\* Every live display was created and not yet destroyed (by construction
\* of live); bound capacity.
Inv_LiveBounded ==
  Cardinality(live) <= MaxLive

Inv_LiveSubsetIds ==
  live \subseteq DisplayIds

\* Successful capture/move/destroy only target a then-live id
\* (encoded in action guards; reflected in lastAction):
Inv_OkTargetsLiveOrCreate ==
  LET status == lastAction[1]
      op     == lastAction[2]
      id     == lastAction[3]
  IN  status = "ok" =>
        \/ op = "create" /\ (id = "-" \/ id \in live)  \* "-" = Init sentinel
        \/ op \in {"move_app","capture"} /\ id \in live
        \/ op = "destroy" /\ id \notin live   \* just removed

\* Refused destroy/move/capture ⇒ id not live.
Inv_RefusedImpliesNotLive ==
  LET status == lastAction[1]
      op     == lastAction[2]
      id     == lastAction[3]
  IN  (status = "refused" /\ op \in {"move_app","capture","destroy"})
        => id \notin live

=============================================================================
