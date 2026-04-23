import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../controllers/transfer_controller.dart';
import '../models/transfer_model.dart';

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TransferController _controller = TransferController();
  TransferModel _model = TransferModel();
  String selectedDest = "A-Variety";
  final TextEditingController _ipController = TextEditingController(text: "192.168.137.203");

  void _updateUI(TransferModel m) => setState(() => _model = m);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(0xFF12122A),
      appBar: AppBar(title: Text("Turbo Transfer Pro"), centerTitle: true, elevation: 0),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(20),
        child: Column(
          children: [
            _buildStatusDisplay(),
            SizedBox(height: 30),
            if (Platform.isWindows) _buildPcInterface(),
            if (Platform.isAndroid) _buildMobileInterface(),
          ],
        ),
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

  Widget _buildPcInterface() {
    return Column(children: [
      TextField(controller: _ipController, style: TextStyle(color: Colors.white),
          decoration: InputDecoration(labelText: "Receiver IP", labelStyle: TextStyle(color: Colors.white38))),
      SizedBox(height: 20),
      Text("Target Folder on Mobile:", style: TextStyle(color: Colors.white70)),
      DropdownButton<String>(
        value: selectedDest, isExpanded: true, dropdownColor: Color(0xFF12122A), style: TextStyle(color: Colors.white),
        items: ["A-Subjects", "A-Variety", "Downloads"].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
        onChanged: (v) => setState(() => selectedDest = v!),
      ),
      SizedBox(height: 25),
      Row(
        children: [
          Expanded(child: _btn(Icons.file_copy, "File", () => _pick(false))),
          SizedBox(width: 15),
          Expanded(child: _btn(Icons.folder, "Folder", () => _pick(true))),
        ],
      ),
    ]);
  }

  Widget _btn(IconData i, String t, VoidCallback fn) => ElevatedButton.icon(
    onPressed: fn, icon: Icon(i), label: Text(t),
    style: ElevatedButton.styleFrom(minimumSize: Size(0, 55), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))),
  );

  Widget _buildMobileInterface() {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(backgroundColor: Colors.green, minimumSize: Size(double.infinity, 60),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
      onPressed: () async {
        Directory? dir = await getExternalStorageDirectory();
        String root = dir!.path.split("/Android")[0];
        _controller.startReceiver(sdcardPath: root, onUpdate: _updateUI);
      },
      icon: Icon(Icons.wifi_tethering),
      label: Text("Start Receiver Server", style: TextStyle(fontSize: 18)),
    );
  }

  Future<void> _pick(bool isFolder) async {
    String? path;
    if (isFolder) {
      path = await FilePicker.getDirectoryPath();
    } else {
      FilePickerResult? r = await FilePicker.pickFiles();
      path = r?.files.single.path;
    }

    if (path != null) {
      _controller.sendData(path: path, targetIp: _ipController.text, targetFolder: selectedDest, isFolder: isFolder, onUpdate: _updateUI);
    }
  }
}