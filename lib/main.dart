import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/video_list_provider.dart';
import 'providers/folder_provider.dart';
import 'screens/video_list_screen.dart';
import 'theme/app_theme.dart';

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
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.system,
        home: const VideoListScreen(),
      ),
    );
  }
}
