import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/video_list_provider.dart';
import 'providers/folder_provider.dart';
import 'screens/video_list_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SnPlayerApp());
}

class SnPlayerApp extends StatelessWidget {
  const SnPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => FolderProvider()),
        ChangeNotifierProvider(create: (_) => VideoListProvider()),
      ],
      child: MaterialApp(
        title: 'SnPlayer',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF6750A4),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xFF1C1B1F),
          appBarTheme: const AppBarTheme(
            centerTitle: false,
            elevation: 0,
          ),
          cardTheme: CardTheme(
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        home: const VideoListScreen(),
      ),
    );
  }
}
