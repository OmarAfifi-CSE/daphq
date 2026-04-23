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
}
