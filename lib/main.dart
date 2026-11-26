import 'package:material_ui/material_ui.dart';
import 'package:nobodywho/nobodywho.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'ui/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NobodyWho.init();
  runApp(const BenchApp());
}

class BenchApp extends StatelessWidget {
  const BenchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ShadApp(
      title: 'LLM Bench',
      debugShowCheckedModeBanner: false,
      theme: ShadThemeData(
        brightness: Brightness.light,
        colorScheme: const ShadZincColorScheme.light(),
      ),
      darkTheme: ShadThemeData(
        brightness: Brightness.dark,
        colorScheme: const ShadZincColorScheme.dark(),
      ),
      home: const HomeScreen(),
    );
  }
}
