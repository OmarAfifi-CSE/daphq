import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../controllers/transfer_controller.dart';
import '../models/transfer_model.dart';

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TransferController _controller = TransferController();
  TransferModel _model = TransferModel();

  bool _isTransferring = false;
  bool _isReceiving = false;
  String? _receiveFolder;

  final TextEditingController _ipController = TextEditingController(text: "192.168.137.1");

  void _updateUI(TransferModel m) => setState(() => _model = m);

  void _setTransferState(bool active) {
    if (mounted) {
      setState(() {
        _isTransferring = active;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(0xFF12122A),
      appBar: AppBar(
        title: Text("Turbo Transfer Pro", style: TextStyle(color: Colors.white)),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Color(0xFF12122A),
        iconTheme: IconThemeData(color: Colors.white),
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(20),
        child: Column(
          children: [
            _buildInstructionsCard(),
            SizedBox(height: 20),
            _buildStatusDisplay(),
            SizedBox(height: 30),
            _buildUnifiedInterface(), // Cross-platform UI
          ],
        ),
      ),
    );
  }

  Widget _buildInstructionsCard() {
    return Container(
      padding: EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(0.1),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.blue.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, color: Colors.blueAccent),
              SizedBox(width: 10),
              Text("How to use for Max Speed", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            ],
          ),
          SizedBox(height: 10),
          Text("1. Create a 5GHz Mobile Hotspot from your PC & connect your Mobile to it.", style: TextStyle(color: Colors.white70, fontSize: 13)),
          SizedBox(height: 5),
          Text("2. Send to PC: Enter the PC's default IP (192.168.137.1) in the Mobile app.", style: TextStyle(color: Colors.white70, fontSize: 13)),
          SizedBox(height: 5),
          Text("3. Send to Mobile: Check PC's Hotspot settings for your Mobile's IP (e.g., 192.168.137.xxx) and enter it in the PC app.", style: TextStyle(color: Colors.white70, fontSize: 13)),
          SizedBox(height: 5),
          Text("4. Always pick a Receiver folder before starting the server.", style: TextStyle(color: Colors.white70, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildStatusDisplay() {
    return Container(
      padding: EdgeInsets.all(25),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        children: [
          Text(_model.status, style: TextStyle(color: Colors.blueAccent, fontSize: 18, fontWeight: FontWeight.bold)),
          SizedBox(height: 15),
          Text("${_model.speed.toStringAsFixed(1)} MB/s",
              style: TextStyle(color: Colors.white, fontSize: 50, fontWeight: FontWeight.bold)),
          if (_model.avgSpeed != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text("Avg: ${_model.avgSpeed} MB/s | Time: ${_model.totalTime}s",
                  style: TextStyle(color: Colors.greenAccent, fontSize: 16)),
            ),
          Divider(color: Colors.white10, height: 40),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _dataTile("Current File", _model.fileName.isEmpty ? "Ready" : _model.fileName),
              _dataTile("Data Size", "${_model.transferred.toStringAsFixed(1)} MB"),
            ],
          )
        ],
      ),
    );
  }

  Widget _dataTile(String label, String val) => Column(children: [
    Text(label, style: TextStyle(color: Colors.white54, fontSize: 12)),
    SizedBox(height: 5),
    Text(val, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold))
  ]);

  Widget _buildUnifiedInterface() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Receiver Section
        Text("Receiver Mode", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        SizedBox(height: 10),
        Container(
          padding: EdgeInsets.all(15),
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(15)),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _receiveFolder == null ? "No receive folder selected" : "Save to: $_receiveFolder",
                      style: TextStyle(color: _receiveFolder == null ? Colors.redAccent : Colors.greenAccent),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.folder_open, color: Colors.white),
                    onPressed: _isTransferring ? null : () async {
                      String? path = await FilePicker.getDirectoryPath();
                      if (path != null) {
                        setState(() => _receiveFolder = path);
                      }
                    },
                  )
                ],
              ),
              SizedBox(height: 15),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isReceiving ? Colors.red : Colors.green,
                  minimumSize: Size(double.infinity, 50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                ),
                onPressed: _isTransferring && !_isReceiving ? null : () {
                  if (_isReceiving) {
                    _controller.stopReceiver();
                    setState(() {
                      _isReceiving = false;
                      _isTransferring = false;
                      _model.status = "Receiver Stopped";
                    });
                  } else {
                    if (_receiveFolder == null) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Please select a receive folder first!")));
                      return;
                    }
                    setState(() {
                      _isReceiving = true;
                      _isTransferring = true;
                    });
                    _controller.startReceiver(
                      saveDirectory: _receiveFolder!,
                      onUpdate: _updateUI,
                      onDone: () {
                        // Keep receiver running for multiple files, or user stops manually
                        // If you want it to close after one transfer, modify the logic.
                      },
                    );
                  }
                },
                icon: Icon(_isReceiving ? Icons.stop : Icons.wifi_tethering, color: Colors.white),
                label: Text(_isReceiving ? "Stop Receiver" : "Start Receiver Server", style: TextStyle(color: Colors.white, fontSize: 16)),
              ),
            ],
          ),
        ),

        SizedBox(height: 30),

        // Sender Section
        Text("Sender Mode", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        SizedBox(height: 10),
        Container(
          padding: EdgeInsets.all(15),
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(15)),
          child: Column(
            children: [
              TextField(
                controller: _ipController,
                style: TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: "Receiver IP",
                  labelStyle: TextStyle(color: Colors.white38),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                ),
                enabled: !_isTransferring,
              ),
              SizedBox(height: 20),
              Row(
                children: [
                  Expanded(child: _btn(Icons.file_copy, "Send File", () => _pick(false))),
                  SizedBox(width: 15),
                  Expanded(child: _btn(Icons.folder, "Send Folder", () => _pick(true))),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _btn(IconData i, String t, VoidCallback fn) => ElevatedButton.icon(
    onPressed: _isTransferring ? null : fn,
    icon: Icon(i, color: Colors.white),
    label: Text(t, style: TextStyle(color: Colors.white)),
    style: ElevatedButton.styleFrom(
      backgroundColor: Colors.blueAccent,
      minimumSize: Size(0, 50),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      disabledBackgroundColor: Colors.white12,
    ),
  );

  Future<void> _pick(bool isFolder) async {
    if (_isTransferring) return;

    String? path;
    if (isFolder) {
      path = await FilePicker.getDirectoryPath();
    } else {
      FilePickerResult? r = await FilePicker.pickFiles();
      path = r?.files.single.path;
    }

    if (path != null) {
      if (_ipController.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Please enter target IP!")));
        return;
      }

      _setTransferState(true);

      _controller.sendData(
        path: path,
        targetIp: _ipController.text.trim(),
        isFolder: isFolder,
        onUpdate: _updateUI,
        onDone: () => _setTransferState(false),
      );
    }
  }
}