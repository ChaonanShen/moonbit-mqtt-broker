///|
pub(all) enum OutboundCommand {
  WriteFrame(Bytes)
  WriteFrameThenClose(Bytes, CloseReason)
} derive(Eq, Debug)

///|
pub struct TransportSink {
  outbound : @async.Queue[OutboundCommand]
  close_signal : @async.Queue[CloseReason]
}

///|
pub fn TransportSink::new(max_outbound : Int) -> TransportSink {
  {
    outbound: @async.Queue(kind=Blocking(max_outbound)),
    close_signal: @async.Queue(kind=Blocking(1)),
  }
}

///|
pub fn TransportSink::outbound(
  self : TransportSink,
) -> @async.Queue[OutboundCommand] {
  self.outbound
}

///|
pub fn TransportSink::close_signal(
  self : TransportSink,
) -> @async.Queue[CloseReason] {
  self.close_signal
}

///|
pub fn TransportSink::close(self : TransportSink) -> Unit {
  self.outbound.close(clear=true)
  self.close_signal.close(clear=true)
}
