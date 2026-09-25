///|
pub(all) enum ReasonPacketKind {
  ConnackReason
  PubackReason
  PubrecReason
  PubrelReason
  PubcompReason
  SubackReason
  UnsubackReason
  DisconnectReason
  AuthReason
} derive(Eq, Debug)

///|
pub fn reason_allowed(
  kind : ReasonPacketKind,
  direction : PacketDirection,
  code : Int,
) -> Bool {
  match kind {
    ConnackReason =>
      direction == ServerToClient &&
      (match code {
        0x00
        | 0x80
        | 0x81
        | 0x82
        | 0x83
        | 0x84
        | 0x85
        | 0x86
        | 0x87
        | 0x88
        | 0x89
        | 0x8a
        | 0x8c
        | 0x90
        | 0x95
        | 0x97
        | 0x99
        | 0x9a
        | 0x9b
        | 0x9c
        | 0x9d
        | 0x9f => true
        _ => false
      })
    PubackReason | PubrecReason =>
      match code {
        0x00 | 0x80 | 0x83 | 0x87 | 0x90 | 0x91 | 0x97 | 0x99 => true
        0x10 => direction == ServerToClient
        _ => false
      }
    PubrelReason | PubcompReason => code == 0x00 || code == 0x92
    SubackReason =>
      direction == ServerToClient &&
      (match code {
        0x00
        | 0x01
        | 0x02
        | 0x80
        | 0x83
        | 0x87
        | 0x8f
        | 0x91
        | 0x97
        | 0x9e
        | 0xa1
        | 0xa2 => true
        _ => false
      })
    UnsubackReason =>
      direction == ServerToClient &&
      (match code {
        0x00 | 0x11 | 0x80 | 0x83 | 0x87 | 0x8f | 0x91 => true
        _ => false
      })
    AuthReason =>
      match code {
        0x18 => true
        0x19 => direction == ClientToServer
        0x00 => direction == ServerToClient
        _ => false
      }
    DisconnectReason =>
      match code {
        0x00
        | 0x80
        | 0x81
        | 0x82
        | 0x83
        | 0x90
        | 0x93
        | 0x94
        | 0x95
        | 0x96
        | 0x97
        | 0x98
        | 0x99 => true
        0x04 => direction == ClientToServer
        0x87
        | 0x89
        | 0x8b
        | 0x8d
        | 0x8e
        | 0x8f
        | 0x9a
        | 0x9b
        | 0x9c
        | 0x9d
        | 0x9e
        | 0x9f
        | 0xa0
        | 0xa1
        | 0xa2 => direction == ServerToClient
        _ => false
      }
  }
}
