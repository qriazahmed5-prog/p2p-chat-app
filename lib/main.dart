import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'p2p_chat_app',
      theme: ThemeData(primarySwatch: Colors.green),
      home: const LoginScreen(),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final nameController = TextEditingController();
  final ipController = TextEditingController(text: "192.168.100.16");

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("P2P Login")),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: "Apna Name Likhain"),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ipController,
              decoration: const InputDecoration(labelText: "Server IP Address"),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                if (nameController.text.isNotEmpty) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ChatHomeScreen(
                        username: nameController.text.trim(),
                        serverIp: ipController.text.trim(),
                      ),
                    ),
                  );
                }
              },
              child: const Text("Connect"),
            ),
          ],
        ),
      ),
    );
  }
}

class ChatHomeScreen extends StatefulWidget {
  final String username;
  final String serverIp;
  const ChatHomeScreen({super.key, required this.username, required this.serverIp});

  @override
  State<ChatHomeScreen> createState() => _ChatHomeScreenState();
}

class _ChatHomeScreenState extends State<ChatHomeScreen> {
  late IO.Socket socket;
  List<String> onlineUsers = [];

  @override
  void initState() {
    super.initState();
    connectToServer();
  }

  void connectToServer() {
    socket = IO.io(
      'http://${widget.serverIp}:3000',
      IO.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .build(),
    );

    socket.connect();

    socket.onConnect((_) {
      socket.emit('register', widget.username);
    });

    socket.on('user_list', (data) {
      setState(() {
        onlineUsers = List<String>.from(data)
            .where((u) => u != widget.username)
            .toList();
      });
    });
  }

  @override
  void dispose() {
    socket.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Hi, ${widget.username}")),
      body: onlineUsers.isEmpty
          ? const Center(child: Text("Koi online nahi hai abhi"))
          : ListView.builder(
              itemCount: onlineUsers.length,
              itemBuilder: (context, index) {
                final user = onlineUsers[index];
                return ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.person)),
                  title: Text(user),
                  trailing: const Icon(Icons.chat),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ChatScreen(
                          socket: socket,
                          myName: widget.username,
                          friendName: user,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}

class ChatScreen extends StatefulWidget {
  final IO.Socket socket;
  final String myName;
  final String friendName;
  const ChatScreen({
    super.key,
    required this.socket,
    required this.myName,
    required this.friendName,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final messageController = TextEditingController();
  final List<Map<String, String>> messages = [];
  
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  bool _inCall = false;

  @override
  void initState() {
    super.initState();
    initRenderers();
    setupSocketListeners();
  }

  Future<void> initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  void setupSocketListeners() {
    widget.socket.on('receive_message', (data) {
      if (data['from'] == widget.friendName) {
        setState(() {
          messages.add({"from": data['from'], "message": data['message']});
        });
      }
    });

    widget.socket.on('incoming_call', (data) async {
      if (data['from'] == widget.friendName) {
        _showIncomingCallDialog(data['offer']);
      }
    });

    widget.socket.on('call_accepted', (data) async {
      if (data['from'] == widget.friendName) {
        var answer = RTCSessionDescription(data['answer']['sdp'], data['answer']['type']);
        await _peerConnection?.setRemoteDescription(answer);
      }
    });

    widget.socket.on('ice_candidate', (data) async {
      if (data['from'] == widget.friendName) {
        var candidate = RTCIceCandidate(
          data['candidate']['candidate'],
          data['candidate']['sdpMid'],
          data['candidate']['sdpMLineIndex'],
        );
        await _peerConnection?.addCandidate(candidate);
      }
    });
  }

  Future<void> _createPeerConnection() async {
    Map<String, dynamic> configuration = {
      "iceServers": [
        {"urls": "stun:stun.l.google.com:19302"}
      ]
    };

    _peerConnection = await createPeerConnection(configuration);

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': {'facingMode': 'user'}
    });

    _localStream!.getTracks().forEach((track) {
      _peerConnection!.addTrack(track, _localStream!);
    });

    _localRenderer.srcObject = _localStream;

    _peerConnection!.onIceCandidate = (candidate) {
      widget.socket.emit('ice_candidate', {
        'to': widget.friendName,
        'from': widget.myName,
        'candidate': candidate.toMap(),
      });
    };

    _peerConnection!.onTrack = (event) {
      if (event.track.kind == 'video') {
        _remoteRenderer.srcObject = event.streams[0];
      }
    };
  }

  Future<void> startVideoCall() async {
    await _createPeerConnection();
    RTCSessionDescription offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);

    widget.socket.emit('call_user', {
      'to': widget.friendName,
      'from': widget.myName,
      'offer': offer.toMap(),
    });

    setState(() => _inCall = true);
  }

  void _showIncomingCallDialog(dynamic offerMap) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text("Incoming Call from ${widget.friendName}"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Reject", style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await _createPeerConnection();
              var offer = RTCSessionDescription(offerMap['sdp'], offerMap['type']);
              await _peerConnection!.setRemoteDescription(offer);
              RTCSessionDescription answer = await _peerConnection!.createAnswer();
              await _peerConnection!.setLocalDescription(answer);

              widget.socket.emit('answer_call', {
                'to': widget.friendName,
                'from': widget.myName,
                'answer': answer.toMap(),
              });

              setState(() => _inCall = true);
            },
            child: const Text("Accept"),
          ),
        ],
      ),
    );
  }

  void endCall() {
    _localStream?.dispose();
    _peerConnection?.close();
    setState(() => _inCall = false);
  }

  void sendMessage() {
    if (messageController.text.trim().isEmpty) return;
    final msg = messageController.text.trim();

    widget.socket.emit('send_message', {
      "to": widget.friendName,
      "from": widget.myName,
      "message": msg,
    });

    setState(() {
      messages.add({"from": widget.myName, "message": msg});
    });
    messageController.clear();
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _localStream?.dispose();
    _peerConnection?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.friendName),
        actions: [
          IconButton(
            icon: const Icon(Icons.videocam),
            onPressed: startVideoCall,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_inCall)
            Container(
              height: 250,
              color: Colors.black,
              child: Stack(
                children: [
                  RTCVideoView(_remoteRenderer),
                  Positioned(
                    right: 10,
                    top: 10,
                    width: 90,
                    height: 120,
                    child: RTCVideoView(_localRenderer, mirror: true),
                  ),
                  Positioned(
                    bottom: 10,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: FloatingActionButton(
                        backgroundColor: Colors.red,
                        onPressed: endCall,
                        child: const Icon(Icons.call_end),
                      ),
                    ),
                  )
                ],
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(10),
              itemCount: messages.length,
              itemBuilder: (context, index) {
                final msg = messages[index];
                final isMe = msg['from'] == widget.myName;
                return Align(
                  alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: isMe ? Colors.green[300] : Colors.grey[300],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(msg['message'] ?? ''),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: messageController,
                    decoration: const InputDecoration(
                      hintText: "Message likho...",
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send, color: Colors.green),
                  onPressed: sendMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
