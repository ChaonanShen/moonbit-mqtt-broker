///|
pub(all) enum QueryKind {
  Listeners
  Connections
  Connection
  Sessions
  Session
  Subscriptions
  Retained
  Config
  Operation
  Audit
} derive(Eq, Debug)

///|
pub(all) enum QueryError {
  QueryBadRequest
  QueryNotFound
  QueryPreconditionFailed
  QueryExpiredCursor
  QueryForbidden
  QueryDetailsUnavailable
  QueryCapacityExhausted
  QueryResultTooLarge
  QueryUnavailable
} derive(Eq, Debug)

///|
/// A bounded request description, created after HTTP authentication. It
/// contains no bearer token, MQTT payload, mutable broker state, or socket.
pub(all) struct QuerySpec {
  kind : QueryKind
  target : String
  actor_token_id : String
  limit : Int
  cursor : String?
  filters : String
}

///|
pub(all) struct QueryEnvelope {
  boot_id : String
  observed_at_ms : Int64
  state_revision : Int64
  items : Array[Json]
  next_cursor : String?
}

///|
pub fn QueryEnvelope::to_json(self : QueryEnvelope) -> Json {
  let object : Map[String, Json] = Map([
    ("api_version", "1".to_json()),
    ("boot_id", self.boot_id.to_json()),
    ("observed_at_ms", self.observed_at_ms.to_string().to_json()),
    ("state_revision", self.state_revision.to_string().to_json()),
    ("consistency", "per_page".to_json()),
    ("items", self.items.to_json()),
    ("next_cursor", self.next_cursor.to_json()),
  ])
  object.to_json()
}

///|
/// ETags include the boot and identity epoch. Queue contents and other
/// business revisions do not change a Session lifecycle ETag.
pub fn connection_etag(boot_id : String, connection_id : Int64) -> String {
  "\"" + boot_id + ":c:" + connection_id.to_string() + "\""
}

///|
pub fn session_etag(
  boot_id : String,
  handle : Int64,
  lifecycle_version : Int64,
) -> String {
  "\"" +
  boot_id +
  ":s:" +
  handle.to_string() +
  ":" +
  lifecycle_version.to_string() +
  "\""
}
