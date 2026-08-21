///|
fn accepted_connack() -> Bytes {
  @protocol.encode_packet(
    @protocol.Packet::Connack({
      session_present: false,
      return_code: @protocol.ConnectReturnCode::Accepted,
    }),
  ).unwrap()
}

///|
async fn handle_m0_connection(
  connection : @socket.Tcp,
  max_packet_size : Int,
  close_after_connack : Bool,
) -> Unit {
  defer connection.close()
  let decoder = @framing.FrameDecoder::new(max_packet_size, max_packet_size)
  let mut connected = false
  for ;; {
    let chunk = match connection.read_some(max_len=4096) {
      Some(bytes) => bytes
      None => return
    }
    match decoder.push(chunk[:]) {
      Err(_) => return
      Ok(_) => ()
    }
    for ;; {
      match decoder.next() {
        @framing.FrameOutcome::NeedMoreData => break
        @framing.FrameOutcome::MalformedPacket(_) => return
        @framing.FrameOutcome::CompletePacket(frame) => {
          let packet = match @protocol.decode_packet(frame) {
            Ok(value) => value
            Err(_) => return
          }
          match
            @protocol.validate_direction(
              packet,
              @protocol.PacketDirection::ClientToServer,
            ) {
            Err(_) => return
            Ok(_) => ()
          }
          if !connected {
            match packet {
              @protocol.Packet::Connect(_) => {
                connection.write(accepted_connack())
                connected = true
                if close_after_connack {
                  return
                }
              }
              _ => return
            }
          } else {
            match packet {
              @protocol.Packet::Disconnect => return
              _ => return
            }
          }
        }
      }
    }
  }
}

///|
/// Accept exactly one connection. Exposed so loopback tests can bind port 0.
pub async fn serve_one(
  listener : @socket.TcpServer,
  max_packet_size : Int,
) -> Unit {
  let (connection, _) = listener.accept()
  handle_m0_connection(connection, max_packet_size, true)
}

///|
pub async fn run(listen : String, max_packet_size : Int, once : Bool) -> Unit {
  let listener = @socket.TcpServer(@socket.Addr::parse(listen), reuse_addr=true)
  defer listener.close()
  println("M0 broker listening on " + listener.addr.to_string())
  if once {
    serve_one(listener, max_packet_size)
  } else {
    listener.run_forever(allow_failure=true, (connection, _) => {
      handle_m0_connection(connection, max_packet_size, false)
    })
  }
}
