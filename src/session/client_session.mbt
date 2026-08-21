///|
pub struct ClientSession {
  client_id : ClientId
} derive(Eq, Debug)

///|
pub fn ClientSession::new(client_id : ClientId) -> ClientSession {
  { client_id, }
}

///|
pub fn ClientSession::client_id(self : ClientSession) -> ClientId {
  self.client_id
}
