import 'package:flutter/material.dart';

class InstructionsCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.blue.withAlpha(25), // withOpacity (0.1) -> withAlpha (25)
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.blue.withAlpha(76)), // withOpacity(0.3) -> withAlpha(76)
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
          Text("1. Connect both devices to the same network (Wi-Fi or Hotspot).", style: TextStyle(color: Colors.white70, fontSize: 13)),
          SizedBox(height: 5),
          Text("2. For max speed, one device should open a 5GHz Hotspot and the other connect to it.", style: TextStyle(color: Colors.white70, fontSize: 13)),
          SizedBox(height: 5),
          Text("3. On the RECEIVER: Select a folder and click 'Start Receiver Server'.", style: TextStyle(color: Colors.white70, fontSize: 13)),
          SizedBox(height: 5),
          Text("4. On the SENDER: Enter the Receiver's IP Address and select what to send.", style: TextStyle(color: Colors.white70, fontSize: 13)),
        ],
      ),
    );
  }
}
