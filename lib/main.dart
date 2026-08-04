import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'ai_provider/ai_module_log.dart';
import 'ai_provider/ai_provider_manager.dart';
import 'core/error_handler.dart';
import 'core/service_locator.dart';
import 'butler/modules/butler_module_hub.dart';
import 'butler/system_template.dart';
import 'data/app_settings.dart';
import 'pages/home/home_page.dart';
import 'utils/debug_logger.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 注册全局错误处理
  ErrorWidget.builder = buildAppErrorWidget;
  registerGlobalErrorHandlers();

  // 先显示启动页，初始化完成后再切换主界面
  runApp(const _BootstrapApp());
}

/// 启动引导页 —— 在后台初始化所有 service，完成后再进入主界面
class _BootstrapApp extends StatelessWidget {
  const _BootstrapApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PocketInn',
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      home: const _BootstrapPage(),
    );
  }
}

class _BootstrapPage extends StatefulWidget {
  const _BootstrapPage();

  @override
  State<_BootstrapPage> createState() => _BootstrapPageState();
}

class _BootstrapPageState extends State<_BootstrapPage> {
  String _status = '正在初始化…';
  String? _error;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    try {
      // 逐步初始化，每一步都带状态更新
      setState(() => _status = '正在初始化服务…');
      await setupServiceLocator();

      setState(() => _status = '正在初始化 AI 路由…');
      // 装配 AI 模块的"插座"：日志接入项目 DebugLogger（2026-08-04 解耦）
      AiModuleLog.configure(DebugLogger.log);
      await AIProviderManager.instance.initialize();

      setState(() => _status = '正在加载管家数据…');
      // 管家模块共享实例（规律/记忆/假面层持久化数据）
      final hub = ButlerModuleHub.instance;
      await hub.loadPersistentData();
      await hub.loadSettings();
      // 用户 8-03 02:49：加载用户编辑过的固定模板覆盖（没有则用默认）
      await SystemTemplate.loadCoreOverride();

      if (!mounted) return;
      // 初始化完成，进入主界面
      setState(() {
        _ready = true;
        _status = '';
      });
    } catch (e, stack) {
      if (!mounted) return;
      setState(() {
        _error = '启动失败:\n$e\n\n$stack';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) {
      // 初始化完成，进入真正的主界面
      return MyApp();
    }

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Logo
              const Icon(
                Icons.home_rounded,
                color: Colors.white54,
                size: 80,
              ),
              const SizedBox(height: 24),
              if (_error != null) ...[
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
                const SizedBox(height: 16),
                SelectableText(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ] else ...[
                const SizedBox(
                  width: 36,
                  height: 36,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: Colors.white38,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _status,
                  style: const TextStyle(color: Colors.white54, fontSize: 15),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppSettings>(
      valueListenable: appSettingsNotifier,
      builder: (context, settings, _) {
        return MaterialApp(
          title: 'PocketInn',
          themeMode: settings.colorMode.themeMode,
          theme: buildAppTheme(settings, Brightness.light),
          darkTheme: buildAppTheme(settings, Brightness.dark),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
          home: const HomePage(),
        );
      },
    );
  }
}
