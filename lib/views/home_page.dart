import 'package:flutter/material.dart';
import 'widgets/instructions_card.dart';
import 'widgets/status_display.dart';
import 'widgets/receiver_section.dart';
import 'widgets/sender_section.dart';

class HomePage extends StatelessWidget {
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
            InstructionsCard(),
            SizedBox(height: 20),
            StatusDisplay(),
            SizedBox(height: 30),
            ReceiverSection(),
            SizedBox(height: 30),
            SenderSection(),
          ],
        ),
      ),
    );
  }
}

