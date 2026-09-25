///|
pub(all) struct Mqtt5IdFloor {
  kind : Int
  new_floor : Int64
} derive(Eq, Debug)

///|
pub(all) struct Mqtt5SessionPut {
  expected_incarnation : Int64
  expected_revision : Int64
  session : SnapshotSessionV5
} derive(Eq, Debug)

///|
pub(all) struct Mqtt5SessionDelete {
  client_id : String
  expected_incarnation : Int64
  expected_revision : Int64
} derive(Eq, Debug)

///|
pub(all) struct Mqtt5GroupPut {
  expected_incarnation : Int64
  expected_revision : Int64
  group : SnapshotGroupV5
} derive(Eq, Debug)

///|
pub(all) struct Mqtt5GroupDelete {
  id : Int64
  expected_incarnation : Int64
  expected_revision : Int64
} derive(Eq, Debug)

///|
pub(all) struct Mqtt5RetainedPut {
  expected_revision : Int64
  retained : SnapshotRetainedV5
} derive(Eq, Debug)

///|
pub(all) struct Mqtt5RetainedDelete {
  topic : String
  expected_revision : Int64
} derive(Eq, Debug)

///|
pub(all) struct Mqtt5WillPut {
  expected_revision : Int64
  will : SnapshotWillV5
} derive(Eq, Debug)

///|
pub(all) struct Mqtt5WillDelete {
  id : Int64
  expected_revision : Int64
} derive(Eq, Debug)

///|
pub(all) struct DurableDeltaV5 {
  new_clock_floor : Int64?
  id_floors : Array[Mqtt5IdFloor]
  session_puts : Array[Mqtt5SessionPut]
  session_deletes : Array[Mqtt5SessionDelete]
  group_puts : Array[Mqtt5GroupPut]
  group_deletes : Array[Mqtt5GroupDelete]
  retained_puts : Array[Mqtt5RetainedPut]
  retained_deletes : Array[Mqtt5RetainedDelete]
  will_puts : Array[Mqtt5WillPut]
  will_deletes : Array[Mqtt5WillDelete]
} derive(Eq, Debug)

///|
pub fn DurableDeltaV5::empty() -> DurableDeltaV5 {
  {
    new_clock_floor: None,
    id_floors: [],
    session_puts: [],
    session_deletes: [],
    group_puts: [],
    group_deletes: [],
    retained_puts: [],
    retained_deletes: [],
    will_puts: [],
    will_deletes: [],
  }
}
