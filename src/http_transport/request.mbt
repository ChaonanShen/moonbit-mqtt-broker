///|
/// Exact bytes between the request line and CRLFCRLF are counted by A03.
/// Fields may contain Authorization; never derive Debug/Show for this type.
pub(all) struct HttpHeader {
  name : String
  value : String
}

///|
pub(all) struct HttpRequestHead {
  method_name : String
  target : String
  version : String
  headers : Array[HttpHeader]
  content_length : Int?
}

///|
pub(all) enum HttpParseError {
  BadRequest
  HeaderTooLarge
  TooManyHeaders
  InvalidLength
} derive(Eq, Debug)

///|
/// consumed is the byte offset immediately after CRLFCRLF. The caller owns
/// any suffix in the same read and applies its own route/body policy.
pub(all) enum HttpParseResult {
  NeedMore
  Complete(HttpRequestHead, Int)
  Reject(HttpParseError)
}
