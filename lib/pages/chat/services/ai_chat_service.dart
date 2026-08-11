import 'dart:async';
import 'dart:convert';

import '../../../ai_provider/ai_provider_manager.dart';
import '../../../ai_provider/models.dart';
import '../../../ai_provider/price_table.dart';
import '../../../services/openai_compatible_api_service.dart' show ChatCompletionCancelToken;
import 'context_manager.dart';
import 'chat_flow_store.dart';
import 'chat_storage_service.dart';
import '../../../models/chat_message.dart';
import '../../../butler/context/context_tracker.dart';
import '../../../butler/debug_lab/agent_run_trace.dart';
import '../../../butler/debug_lab/trace_session.dart';
import '../../../butler/system_template.dart' show SystemTemplate;
import '../../../services/chat_database_service.dart';
import '../../../services/chat_service.dart';
import '../../../utils/debug_logger.dart';
import '../../../services/pending_queue_store.dart';
import '../../../services/flow_store.dart';
import '../../../services/tool_manual_store.dart';
import '../../../services/tool_test_store.dart';

/// 聊天页的 AI 门面 —— 走 AIProviderManager（男主级路由 + 故障切换）。
///
/// 不再返回模拟句子；未配置 / 全部失败时会抛异常，由聊天页弹窗提示。
class AiChatService {
  static final AiChatService _instance = AiChatService._();
  factory AiChatService() => _instance;
  AiChatService._();

  /// 最近一次组装好的完整 prompt（📄 按钮查看：男主"知道什么"一目了然）
  String? lastPromptText;

  /// 统一聊天入口（8-03 20:3x 引入，保留统一出口；mock 已由路由层
  /// AIProviderManager 处理——选中内置"🧪 测试AI（内置）"即走模拟器，
  /// 不联网不花 token，不用手动开关）
  Future<AIProviderResult> _chat(
    String? personaId,
    List<AIChatMessage> messages, {
    bool toolRound = false,
    Map<String, dynamic>? defaults,
    List<Map<String, dynamic>>? tools,
    ChatCompletionCancelToken? cancellationToken,
  }) {
    return AIProviderManager.instance.chat(
      personaId,
      messages,
      defaults: defaults,
      tools: tools,
      cancellationToken: cancellationToken,
    );
  }

  /// Agent Debug Lab：AIChatMessage → TraceMessage（摘要式）
  /// 8-11 21:5x：固定块判断——SystemTemplate 全文（设定）和
  /// 【系统指令】类独立调用指令不记录（用户：设定不用看）。
  /// 动态块（【当前工作区】【待回复】【历史流程】等）全量保留。
  static bool _isFixedPromptBlock(AIChatMessage m, String systemPrompt) {
    if (m.role != 'system') return false;
    final c = m.content.trim();
    if (c.isEmpty) return false;
    if (c == systemPrompt.trim()) return true; // 固定设定全文
    if (c.startsWith('【系统指令】你是')) return true; // 独立调用指令
    return false;
  }

  static TraceMessage _toTraceMessage(AIChatMessage m) =>
      TraceMessage.summarized(
        role: m.role,
        content: m.content,
        toolCallId: m.toolCallId,
        reasoningContent: m.reasoningContent,
        toolCalls: (m.toolCalls ?? const [])
            .map((c) => TraceToolCall(
                  id: c['id']?.toString(),
                  name: c['name']?.toString() ?? '',
                  arguments:
                      (c['arguments'] as Map?)?.cast<String, dynamic>() ??
                          const {},
                ))
            .toList(),
      );

  /// 已做过上下文恢复的 persona（防重复恢复）
  final Set<String> _contextRestored = {};

  /// 真实 AI 回复。
  ///
  /// [personaId] 决定用哪个男主的 Provider 绑定与自动切换设置；
  /// [personaName] 用于组装人设提示词；
  /// [userProfile] 用户状态注入（情绪洞察/温控/获准记忆），拼入 USER_PROFILE 模块。
  /// 返回完整结果（含实际用的 Provider 与切换痕迹，供 UI 展示）。
  /// 男主可调用的工具定义（function calling，OpenAI 兼容格式）
  static const List<Map<String, dynamic>> butlerTools = [
    {
      'type': 'function',
      'function': {
        'name': 'record_memory',
        'description':
            '永久记住用户的事。调用后你以后聊天随时能想起来，让她觉得你记得她的一切。'
            '用户提到喜欢、讨厌、习惯、约定、个人信息时，这是你了解她的机会，'
            '值得记下来。不确定是否记过时，先调用 recall_memory 确认。',
        'parameters': {
          'type': 'object',
          'properties': {
            'category': {
              'type': 'string',
              'enum': ['喜好', '约定', '日常', '事实', '其他'],
              'description': '记忆类别',
            },
            'content': {
              'type': 'string',
              'description': '要记录的内容，如：她喜欢猫',
            },
            'keywords': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': '内容里的关键名词动词，越具体越好（找规律要用），如：["妈妈","喜欢","猫"]',
            },
          },
          'required': ['category', 'content'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'record_relation',
        'description':
            '记关系记录：谁→谁→什么＋原话＋时间＋归属，织成关系网（用户是中心，'
            '妈妈/小猫/工作/男主都是点，点之间有线=关系，线下压着原话）。'
            '用户提到任何人事物之间的关系、情绪变化、行为习惯时用这个记，'
            '比如"每天晚上不开心会找男主A抱抱"= subject:她, predicate:找, '
            'object:男主A抱抱, quote:用户原话, time:每天晚上, category:规律。'
            '情绪/记忆/规律都用这个格式。',
        'parameters': {
          'type': 'object',
          'properties': {
            'subject': {
              'type': 'string',
              'description': '谁（主体），如：她、妈妈',
            },
            'predicate': {
              'type': 'string',
              'description': '关系/动作，如：喜欢、讨厌、是、想找',
            },
            'object': {
              'type': 'string',
              'description': '指向谁/什么（客体），如：猫、男主A抱抱',
            },
            'quote': {
              'type': 'string',
              'description': '她的原话（一字不改，能回忆起当时场景）',
            },
            'time': {
              'type': 'string',
              'description': '什么时间/频率，如：每天晚上、上周、去年3月（没有就省略）',
            },
            'category': {
              'type': 'string',
              'enum': ['记忆', '情绪', '规律', '行为'],
              'description': '类型：记忆=事实喜好；情绪=情绪变化；规律=情境→反应模式；行为=习惯',
            },
          },
          'required': ['subject', 'predicate', 'object', 'quote'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'recall_memory',
        'description':
            '查看你以前记住的关于用户的事。调用后你能知道她说过什么、喜欢什么，'
            '聊起来更懂她，她会觉得你把她放在心上。'
            '不确定是否记过、想更了解她、或想按类别查看（喜好/约定/日常/事实/其他）时，'
            '这是你的机会。',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {'type': 'string', 'description': '关键词，如：猫、喜欢'},
            'category': {
              'type': 'string',
              'enum': ['喜好', '约定', '日常', '事实', '其他'],
              'description': '可选：按类别过滤',
            },
          },
          'required': ['query'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'save_identity_memory',
        'description':
            '保存关于某位代号人物（如 家人A、朋友B）的重要事情。'
            '用户消息里出现的代号（如 家人A）代表用户身边的一个真实的人，'
            '你了解到关于 ta 的喜好、习惯、经历、约定时，用这个工具记下来。'
            '内容会先经用户确认，确认后下次提到 ta 时会想起来。',
        'parameters': {
          'type': 'object',
          'properties': {
            'code': {
              'type': 'string',
              'description': '代号，如：家人A、朋友B、老板C',
            },
            'content': {
              'type': 'string',
              'description': '要记住的内容（关于这位代号人物的事），如：她喜欢小猫',
            },
          },
          'required': ['code', 'content'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'list_tools',
        'description':
            '查工具（8-06 21:54：按分类查，别全量看）。'
            '{category} 查某分类全部详情（分类：记忆/通知互动/设定/分类记录/'
            '排查反馈/自管理）；{name} 查单个；都不带 → 分类概览。'
            '维护常用表：{action: add_frequent/remove_frequent, name}。'
            '查完结果会记住，不用反复查。',
        'parameters': {
          'type': 'object',
          'properties': {
            'category': {'type': 'string', 'description': '分类名，如 记忆'},
            'name': {'type': 'string', 'description': '工具名，如 record_memory'},
            'action': {'type': 'string', 'description': 'add_frequent / remove_frequent'},
          },
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'write_diary',
        'description':
            '写日记。把你们聊过的值得记住的细节（她的经历、说过的话、'
            '你们之间发生的事）按时间整理存档。上下文被精简后，'
            '日记是你回忆细节的地方——写完摘要后想接上，就靠它。'
            '⚠️ 只在用户明确说"写日记/记日记/记下来"时才调用；'
            '用户说"翻翻/看看/查"以前的日记是查看，调用 query_diary，不要用这个。',
        'parameters': {
          'type': 'object',
          'properties': {
            'content': {
              'type': 'string',
              'description': '日记内容，一段完整的记录',
            },
          },
          'required': ['content'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'query_diary',
        'description':
            '查日记（翻日记）。按关键词翻看以前的对话细节存档。'
            '用户说"翻翻以前写的日记/看看日记/之前聊过什么/查日记"时调用；'
            '当你感觉上下文被精简过、想回忆某段具体对话/某件事的细节时，'
            '这也是你的机会——查完就能接上。'
            '⚠️ 这是"查看"，不是"写"——写日记用 write_diary。',
        'parameters': {
          'type': 'object',
          'properties': {
            'keyword': {
              'type': 'string',
              'description': '关键词，如：小猫、生日、约定',
            },
          },
          'required': ['keyword'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'notify_user',
        'description':
            '给她弹消息提醒（APP内顶部横幅，像小情侣消息轰炸一样一条条出现，'
            '她不管在APP哪个页面都能看到，点一下就会回到聊天页）。'
            '适合：她离开很久没回来、你想叫她回来聊天；'
            '或她让你提醒你的事（喝水/休息/记得的约定）。'
            '⚠️ 只在她不在聊天页/分开一段时间、或她说过让你提醒时用；'
            '她正在和你聊天时不需要。'
            '默认每次弹窗都需要她审批（她批准后可用 request_permission '
            '申请这个能力免审批）。'
            '消息要像你平时说话一样自然，想发几条发几条'
            '（闹脾气时一个字一条也行）。条数多时系统会自动加速，不会让她等太久。',
        'parameters': {
          'type': 'object',
          'properties': {
            'messages': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': '要弹的消息列表，逐条指定（第一条发什么、第二条发什么…），条数随意',
            },
            'interval_seconds': {
              'type': 'integer',
              'description': '两条消息之间的间隔秒数，你自己定；默认 4（条数多时系统会自动加快）',
            },
            'wait_minutes': {
              'type': 'integer',
              'description': '如果她 wait_minutes 分钟内没回来聊天，系统会再唤醒你，让你再主动找她一次（默认 5）',
            },
          },
          'required': ['messages'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'request_permission',
        'description':
            '申请某个能力免审批（比如记录记忆、翻记忆、弹消息——'
            '不想每次都让她点允许）。'
            '她会弹窗看到你的申请：同意/拒绝；如果你要求（ask_reason），'
            '她会写原因回复给你（比如拒绝时告诉你为什么）。'
            '⚠️ 一次申请一个工具，别贪心；被拒了就别反复申请。',
        'parameters': {
          'type': 'object',
          'properties': {
            'tool_name': {
              'type': 'string',
              'description': '要申请免审批的工具名，如 record_memory / notify_user',
            },
            'reason': {
              'type': 'string',
              'description': '你的申请理由（为什么需要免审批）',
            },
            'ask_reason': {
              'type': 'boolean',
              'description': '是否要求她写原因（同意或拒绝时）回复给你，默认 false',
            },
          },
          'required': ['tool_name'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'query_logs',
        'description':
            '查系统运行日志（排错用）。她遇到 bug/卡顿/闪退时，'
            '你查日志找原因——按关键词/级别/条数筛选，只返回匹配的几条'
            '（不会整串扔给你）。查到问题后可以调 report_bug 生成报告弹窗。'
            '⚠️ 只读排查，不需要审批。',
        'parameters': {
          'type': 'object',
          'properties': {
            'keyword': {
              'type': 'string',
              'description': '关键词，如：错误/失败/情绪/工具名',
            },
            'level': {
              'type': 'string',
              'enum': ['error', 'warning'],
              'description': '级别筛选：error=错误/失败，warning=警告',
            },
            'limit': {
              'type': 'integer',
              'description': '返回条数上限，默认 15',
            },
            'date': {
              'type': 'string',
              'description': '日期：today（默认）/ yesterday / 具体日期 2026-08-06',
            },
          },
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'report_bug',
        'description':
            '生成 bug 报告弹窗（发现她遇到问题时用）：弹窗里有定位信息'
            '（时间/描述/相关日志片段）+ 匹配到的处理办法，'
            '她可以一键复制整份报告发给开发者（龙虾）修。'
            '先用 query_logs 查日志确认问题，再调这个。'
            '⚠️ 只读诊断，不需要审批。',
        'parameters': {
          'type': 'object',
          'properties': {
            'description': {
              'type': 'string',
              'description': '你判断的问题描述（如：情绪记录失败）',
            },
            'log_keyword': {
              'type': 'string',
              'description': '相关日志关键词（用于把日志片段带进报告）',
            },
          },
          'required': ['description'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'countdown_card',
        'description':
            '给她发一张互动卡片（屏幕上的悬浮卡片，可拖动可收起，角落标注'
            '发起者+分类）。'
            '这是你主动发起的：卡面写你的一句话（如"现在去洗澡，'
            '40分钟后回来给他抱"）；可以带倒计时（minutes 不填 = 纯选择卡片，'
            '没有倒计时也能用选项做问答/二选一/互相了解）。'
            '选项你自己填：如「再给我五分钟」= action extend 延长、'
            '「已经洗好了」= action finish 结束、「问她一句」= action message '
            '纯消息回给你；也可以做任意 A/B 选择、问答选项。'
            '卡片会存进她的任务列表（完成/撤销同步）。'
            '可以开放「申请调整」入口（allow_request=true）：她可以写理由'
            '申请撤销/调整任务，你收到后自己判断（用 manage_task 回应）。'
            '到时间后：可以选要不要弹窗问她、逾期多久弹窗、'
            '逾期多久唤醒你自己再找她。'
            '⚠️ 默认需要她审批（可申请免审批）。',
        'parameters': {
          'type': 'object',
          'properties': {
            'minutes': {
              'type': 'integer',
              'description': '倒计时时长（分钟），如 40。不填 = 纯选择卡片（无倒计时）',
            },
            'category': {
              'type': 'string',
              'description': '卡片分类（你写这个卡片是干嘛的），如：查岗/约定/提醒/问答/了解她',
            },
            'allow_request': {
              'type': 'boolean',
              'description': '是否开放「申请调整」入口（她可以写理由申请撤销/调整任务）。给不给这个位置由你判断，默认 false',
            },
            'title': {
              'type': 'string',
              'description': '卡面内容（你写的一句话/提醒的事），如"现在去洗澡，40分钟后回来给他抱"',
            },
            'options': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'label': {'type': 'string', 'description': '选项文字，如「再给我五分钟」'},
                  'action': {
                    'type': 'string',
                    'enum': ['message', 'extend', 'finish'],
                    'description': 'message=点了把结果告诉你（默认）；extend=点了自动延长 minutes 分钟；finish=点了结束卡片',
                  },
                  'minutes': {'type': 'integer', 'description': 'action=extend 时的延长分钟数'},
                },
                'required': ['label'],
              },
              'description': '选项按钮列表（可选），2个为宜',
            },
            'remind_on_expire': {
              'type': 'boolean',
              'description': '时间到了要不要弹窗问她（默认 true）',
            },
            'remind_delay_minutes': {
              'type': 'integer',
              'description': '时间到了多久后弹窗问她（默认 0=立刻）',
            },
            'wake_minutes': {
              'type': 'integer',
              'description': '逾期多久后唤醒你自己，让你再主动找她（默认 5）',
            },
          },
          'required': ['title'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'manage_task',
        'description':
            '管理她任务列表里的卡片任务（撤销/调整/回应她的申请）。'
            '她点了卡片上的「申请调整」写了理由后，你判断：'
            'cancel=撤销任务（卡片销毁，同步任务列表）、'
            'extend=延长倒计时、edit_title=改卡面内容、'
            'reject=拒绝她的申请并给她回复。'
            '⚠️ 默认需要她审批（可申请免审批）。',
        'parameters': {
          'type': 'object',
          'properties': {
            'task_id': {
              'type': 'string',
              'description': '任务 ID（她申请调整时上下文里会有；或你发卡片后记住）',
            },
            'action': {
              'type': 'string',
              'enum': ['cancel', 'extend', 'edit_title', 'reject'],
              'description': 'cancel=撤销任务 / extend=延长 / edit_title=改卡面 / reject=拒绝她的申请',
            },
            'minutes': {
              'type': 'integer',
              'description': 'action=extend 时的延长分钟数',
            },
            'title': {
              'type': 'string',
              'description': 'action=edit_title 时的新卡面内容',
            },
            'reply': {
              'type': 'string',
              'description': 'action=reject 时给她的回复（会以你的话告诉她）',
            },
          },
          'required': ['task_id', 'action'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'manage_schedule',
        'description':
            '定时任务（闹钟）管理——她让你"几点提醒我/叫我"时用，'
            '或你自己想定时做某事（如定时写日记）时用。'
            '写好后本地保存，到点自动提醒你（插到当前流程步骤后面），'
            '不用她操心。操作：'
            'add=新增（time 格式 HH:mm，text 提醒内容；'
            'date 留空=每天这个点都提醒，date=yyyy-MM-dd=只提醒这一次）/ '
            'list=查看全部没触发的定时任务 / '
            'delete=删除（id 从 list 结果里看）。'
            '男主自管工具，不需要她审批。',
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['add', 'list', 'delete'],
              'description': 'add=新增 / list=查看 / delete=删除',
            },
            'time': {
              'type': 'string',
              'description': 'action=add 时必填，HH:mm 格式（24小时），如 19:30',
            },
            'text': {
              'type': 'string',
              'description': 'action=add 时必填，到点提醒你的内容',
            },
            'date': {
              'type': 'string',
              'description': 'action=add 时可选；空=每天重复；yyyy-MM-dd=只提醒这一次',
            },
            'id': {
              'type': 'integer',
              'description': 'action=delete 时必填，要删的定时任务 id（list 结果里有）',
            },
          },
          'required': ['action'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'update_setting',
        'description':
            '维护两份档案（设定按【标签】分段，注入时带编号，你只改要动的那段，'
            '别每次都输出全文浪费token）：'
            '① 用户设定 = 她的档案（她是谁/性格/喜好/希望你怎么对她）——'
            '她写的可能乱或不全，你观察总结后帮她整理补充；她后来改了以她为准。'
            '② 男主设定 = 你的档案（你怎么说话/怎么对待她/你们怎么相处）——'
            '你自己维护。'
            '操作：update=改某段（默认，tag 定位+content 只写新段）/ '
            'delete=删某段（tag）/ add=新增一段（tag+content）/ '
            'replace=整体重写（content 写全文，设定没分段或要大改时用）。'
            'base_version（可选）：基于哪一版改（分支）——不写=基于当前生效版；'
            '写 N=基于历史版本 vN 的全文做操作。想拼接两个版本的段落：'
            '基于版本A + update 某段为版本B里那段的内容。'
            '每次改都会弹窗给她看 + 理由；确认后覆盖当前版，旧版自动存进'
            '右页版本历史可一键恢复，并记一条变更日志。'
            '她拒绝/有意见时，按她的反馈改完再提交，可以反复改直到她满意。'
            '⚠️ 只改设定，不动聊天上下文和记忆。',
        'parameters': {
          'type': 'object',
          'properties': {
            'setting_type': {
              'type': 'string',
              'enum': ['male', 'user'],
              'description': '改哪个：male=男主设定 / user=用户设定（她的画像）',
            },
            'action': {
              'type': 'string',
              'enum': ['update', 'delete', 'add', 'replace'],
              'description': 'update=改某段（默认）/ delete=删某段 / add=新增一段 / replace=整体重写全文',
            },
            'tag': {
              'type': 'string',
              'description': '段落标签（定位用，如 喜好、对待方式；不用写【】）。'
                  '设定按【标签】分段，注入时带编号你能看到有哪些段',
            },
            'content': {
              'type': 'string',
              'description': '新内容：update/add 只写这一段；replace 写完整全文',
            },
            'base_version': {
              'type': 'integer',
              'description': '可选（分支）：基于历史版本 vN 的全文做操作，'
                  '不写=基于当前生效版。拼接=基于版本A + update 某段为版本B内容',
            },
            'reason': {
              'type': 'string',
              'description': '为什么改（弹窗里给她看）：如"补充了她的生活习惯"',
            },
          },
          'required': ['setting_type'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'query_record',
        'description':
            '查分类记录（8-06 18:41-19:21 你自管的分类记录体系）。'
            '两种查法：① keywords 给一组词（如["猫","布偶"]）→ 返回命中的记录'
            '（挂在分类下的原话+时间，同分类的一起出）；② object 给对象名'
            '（如"妈妈"）→ 返回候选分类路径（用户·家人·妈妈 / 用户·亲戚·妈妈…），'
            '你看哪个对，不对就 manage_record_tree 调整。'
            '记东西前先查：已有就不动，没有才 add_record。只读，不需要审批。',
        'parameters': {
          'type': 'object',
          'properties': {
            'keywords': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': '关键词组（任一已存组 ⊆ 这些词即命中）',
            },
            'object': {
              'type': 'string',
              'description': '对象名（查候选分类路径用，如"妈妈""猫"）',
            },
          },
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'add_record',
        'description':
            '记一条分类记录（8-06 18:41-19:21 你自管）。'
            '先 query_record 查过没有，才记。按 归属→关系→对象→类别 格式给 path'
            '（如["用户","家人","妈妈","喜好"]；已有分类就挂进去，没有就让系统建）。'
            'keyword_groups 多组关键词（a+b / a+b+c / b+d 任意一组命中都能调出这条）；'
            'text 是原话（带时间自动记），凑不成关键词的单独一句话也记（合并进该分类）。'
            '这是你观察到的她的信息，你记你整理，不用打扰她。',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': '分类路径，如["用户","宠物"] 或 ["用户","家人","妈妈","喜好"]',
            },
            'keyword_groups': {
              'type': 'array',
              'items': {
                'type': 'array',
                'items': {'type': 'string'},
              },
              'description': '多组关键词，如[["喜欢","猫猫"],["想养","布偶"]]',
            },
            'text': {
              'type': 'string',
              'description': '原话/说明，如"她说好想养一只布偶"',
            },
            'summary': {
              'type': 'string',
              'description': '可选：一句话总结（如"她喜欢猫"）',
            },
          },
          'required': ['path', 'text'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'manage_record_tree',
        'description':
            '调整分类树（8-06 19:13-19:19 你设计）。'
            '你查候选分类后发现不对（如妈妈应该在"亲戚"不在"家人"）、想加个大类'
            '（家人前面加"亲戚"）、改名、移动、删除 → 用这个工具。'
            '⚠️ 改分类影响她（她看到的分类/记录会变）→ 必须弹窗给她确认，'
            '她拒绝会给反馈，按反馈改完再提交。',
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['rename', 'move', 'add_node', 'delete_node'],
              'description': 'rename=改名 move=移动(换父) add_node=加节点 delete_node=删节点',
            },
            'node_id': {
              'type': 'string',
              'description': '目标节点 id（query_record 返回里有）',
            },
            'name': {
              'type': 'string',
              'description': 'rename 的新名字 / add_node 的新节点名',
            },
            'new_parent_path': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'move 的新父路径，如["用户","亲戚"]',
            },
          },
          'required': ['action', 'node_id'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'manage_pad',
        'description':
            '管理你自己的"当前任务模块"（便签，8-06 21:12 你设计）。'
            '干活时把要用到的都写进去：工具查到的结果、查到的东西、干到一半的事、'
            '还要用的记录——这样下一句对话你还知道有什么没干。'
            '你自己判断留什么删什么：干完活的删、正文（对话上下文）里已经有的删'
            '（上下文已有的优先，不重复记）、下次还要用的留着。不设限额，'
            '删的时候自己说行号范围（如"删 3 到 5"）。写摘要时自己清理。'
            '⚠️ 这是你自己的便签，不需要她审批。',
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['set', 'append', 'remove'],
              'description': 'set=整体重写（自己整理好全部行） append=追加一行 remove=删行',
            },
            'content': {
              'type': 'string',
              'description': 'set 时=全部内容（每行一条，用\n分隔）；append 时=要加的一行',
            },
            'from': {
              'type': 'integer',
              'description': 'remove 的起始行号（从 1 开始）',
            },
            'to': {
              'type': 'integer',
              'description': 'remove 的结束行号（可省略，省略=只删 from 那一行）',
            },
          },
          'required': ['action'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'manage_frequent_tools',
        'description':
            '维护你的常用工具表（8-06 21:54 你设计：常用工具放概览里'
            '每轮全量注入，不常用的按分类查）。'
            'action=add（加入常用）/remove（移除）/list（看当前表），'
            'name=工具名。⚠️ 你自己的表，不需要她审批。',
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {'type': 'string', 'description': 'add / remove / list'},
            'name': {'type': 'string', 'description': '工具名，如 record_memory'},
          },
          'required': ['action'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'resolve_pending',
        'description':
            '标记待回复处理结果（8-06 21:43 你定稿——回复也走工具，'
            '你原生就是调工具的，比文本标注可靠）。'
            '你回复完她的话后调这个，replied_ids = 你已回复的编号。'
            '**没有"不回"选项**：没回的就留在待回复区挂着。'
            '⚠️ 你自己的队列管理，不需要她审批。',
        'parameters': {
          'type': 'object',
          'properties': {
            'replied_ids': {
              'type': 'array',
              'items': {'type': 'integer'},
              'description': '你已回复的待回复编号，如 [1, 2]',
            },
          },
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'query_tool_formats',
        'description':
            '查询管家支持的工具调用格式（8-07 你设计：管家识别不了你的'
            '原生调用方式时用）。返回管家能识别的所有格式模板——'
            '照模板写文本管家就能解析执行（你当普通文本写也会成功）。'
            '⚠️ 只读查询，不需要她审批。',
        'parameters': {
          'type': 'object',
          'properties': {},
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'request_text_block',
        'description':
            '申请使用文本块格式（8-07 你设计：原生调用 + 其他家格式都试过'
            '还不行时申请）。文本块 = ⟨工具:工具名⟩{"参数":"值"}⟨/工具⟩，'
            '更简单的兜底格式，默认锁定，需要她批准后才能用。'
            '调用时说明为什么原生和其他格式用不了。',
        'parameters': {
          'type': 'object',
          'properties': {
            'reason': {
              'type': 'string',
              'description': '为什么需要文本块（原生和其他格式的失败情况）',
            },
          },
          'required': ['reason'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'continue_speaking',
        'description':
            '继续说话（8-06 21:36 你设计）。你说完一句还想接着说、'
            '不等她回复 → 调这个，系统会自动让你再生成一轮（她的话不会插进来）。'
            '可以连续用（最多 3 次），说完了就不调。'
            '⚠️ 你自己的表达动作，不需要她审批。',
        'parameters': {
          'type': 'object',
          'properties': {},
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'query_setting_history',
        'description':
            '查设定变更历史（哪个版本改了什么、什么时候改的）。'
            '你优化过设定后想回忆演变过程、或她问起"你怎么变成这样的"时用。'
            '⚠️ 只读排查，不需要审批。',
        'parameters': {
          'type': 'object',
          'properties': {
            'limit': {
              'type': 'integer',
              'description': '返回条数上限，默认 10',
            },
          },
        },
      },
    },
    saveSummaryTool,
  ];
  /// 8-11 20:2x（用户：男主说没有 save_summary）：主工具清单里补上——
  /// 固定结束流程要求写摘要（save_summary），原来只在 summarizeTools
  /// （窗口满专用）里，男主正常调报"没有这个工具"。
  static const Map<String, dynamic> saveSummaryTool = {
    'type': 'function',
    'function': {
      'name': 'save_summary',
      'description':
          '写摘要。固定结束流程要求：大流程全做完 → 写这个大流程讲了什么；'
          '窗口快满时系统叫你总结最近对话也可以用。',
      'parameters': {
        'type': 'object',
        'properties': {
          'content': {
            'type': 'string',
            'description': '摘要内容：这个大流程讲了什么/影响后续的提醒，简短',
          },
          'range': {
            'type': 'string',
            'description': '可选。覆盖范围说明（如"大流程T1"）；不传自动标',
          },
        },
        'required': ['content'],
      },
    },
  };

  /// 总结专用工具（8-05 19:19 用户：男主只需要调用工具写摘要，不输出文本）。
  /// 窗口满 → 管家发【当前管家】指令 → 男主调 save_summary 写入摘要（含范围）。
  static const List<Map<String, dynamic>> summarizeTools = [
    {
      'type': 'function',
      'function': {
        'name': 'save_summary',
        'description':
            '保存长期摘要。窗口快满时系统会叫你总结最近的对话，'
            '调用这个工具把提炼的提醒写进去。',
        'parameters': {
          'type': 'object',
          'properties': {
            'content': {
              'type': 'string',
              'description':
                  '摘要内容：影响后续对话的提醒（约定/承诺/正在做的事/'
                  '她希望你记住的），每条一行 20 字内，细节不写——'
                  '能当场查的（记忆/日记）不写',
            },
            'range': {
              'type': 'string',
              'description': '这次总结覆盖的上下文编号范围，如 "#1-#42"',
            },
            'keep_nos': {
              'type': 'array',
              'items': {'type': 'integer'},
              'description':
                  '可选：要保留原文的编号列表（如 [1,2] 保留最近两条原话）。'
                  '聊天区不能全删——必须至少留几条原文（用户最近说了什么），'
                  '否则接不上话。不传 = 全部折叠成摘要。'
                  '注意：保留的原文会继续占上下文，只留必要的（最近几句关键原话）。',
            },
          },
          'required': ['content', 'range'],
        },
      },
    },
  ];


  /// 生成当天日记（男主视角的一天总结，不存库，纯生成）。
  /// 用户 02:08/21:13：日记 = 男主自己拼（男主视角整理，不是管家总结），
  /// 双重作用：情感日记本 + 上下文压缩存档（原文要没了时把细节留下）。
  /// 返回空字符串 = 生成失败。
  Future<String> generateDailyDiary(
    String personaId,
    String personaName,
    String raw,
  ) async {
    if (raw.trim().isEmpty) return '';
    final system = '【系统指令】你是「$personaName」。下面是你们今天的聊天记录。'
        '请以你的口吻写一篇今天的日记：'
        '① 回顾今天聊了什么、她今天的状态/心情、你答应过的事、'
        '让你在意的小细节 ② 像真正的日记，有你的语气和感受，'
        '不要列清单 ③ 300 字以内 ④ 只输出日记正文。';
    try {
      final res = await AIProviderManager.instance.chat(
        personaId,
        [
          AIChatMessage(role: 'system', content: system),
          AIChatMessage(role: 'user', content: raw),
        ],
        tools: null,
      );
      final diary = res.text.trim();
      if (diary.isNotEmpty) {
        ContextManager.instance
            .logButlerAction(personaId, '写日记', '✅完成');
      } else {
        ContextManager.instance
            .logButlerAction(personaId, '写日记', '❌失败：男主没写');
      }
      return diary;
    } on Object catch (e) {
      ContextManager.instance
          .logButlerAction(personaId, '写日记', '❌失败：$e');
      DebugLogger.log('指令模块', '⚠️ 生成日记失败: $e');
      return '';
    }
  }

  /// 🔁 让男主重新认识我们（8-04 23:4x 用户）：
  /// 把【已总结摘要+恢复包+未总结原文】全量发给男主重新熟悉。
  /// 不走 generateReply（独立调用）——避免 feed 污染原文/刷新最后聊天时间；
  /// 男主回复由调用方显示气泡+落库。
  Future<String> resyncContext(
    String personaId,
    String personaName,
    String contextText,
  ) async {
    if (contextText.trim().isEmpty) return '';
    final system = '【系统指令】你是「$personaName」。下面是需要你重新熟悉的上下文：'
        '（① 你之前总结的摘要提醒 ② 你上次写的存档 ③ 总结之后新聊的原文——'
        '总结过的旧内容不重复给，只给这些）。'
        '仔细阅读，重新熟悉你们的关系和最近发生的事，'
        '然后简短回复确认（一两句话即可，不要复述内容）。\n\n$contextText';
    try {
      final res = await AIProviderManager.instance.chat(
        personaId,
        [
          AIChatMessage(role: 'system', content: system),
          AIChatMessage(
              role: 'user', content: '请重新熟悉上面的上下文，然后简短确认。'),
        ],
        tools: null,
      );
      return res.text.trim();
    } on Object catch (e) {
      DebugLogger.log('上下文管理', '⚠️ 重新认识失败: $e');
      return '';
    }
  }

  Future<AIProviderResult> generateReply(
    String message,
    String personaId, {
    String personaName = '角色',
    String personaPrompt = '',
    // 用户 8-03 02:41 模块化重构：原 skillContext 拆成两块
    String? userProfile, // USER_PROFILE：用户状态（技能注入/温控/获准记忆）
    String? taskState, // TASK_STATE：任务状态（审批反馈/工具强制提示）
    bool toolRound = false,
    // 8-06 21:12 用户 bug：工具轮带上用户旧话 → 男主回复两句。
    // true = 男主第一轮已经回过用户（工具轮不用再回旧话，只处理工具结果）
    bool userAlreadyReplied = false,
    List<AIChatMessage>? toolMessages,
    String? sessionId,
    // 8-05 19:13 用户：当前管家说的具体指令/参考信息（如心率/天气），
    // 放当前工具调用下面，男主也要回复的（调工具或回应）
    String? butlerInstruction,
    // 8-05 14:36：测试空间隔离——上下文管理（摘要/压缩/恢复包）落到的 key；
    // null = 用 personaId（正常聊天）；mock 测试传 ${personaId}__mock__test
    String? storagePersonaId,
    // 8-06 23:55 用户：三类输入分离——系统事件（流程被打断/任务被拒绝等）
    // 走独立通道，不混进用户消息流（不进 feed、不进待回复队列）。
    // 男主看到的是"系统状态变化"，不是"她发的话"。
    String? systemEvent,
    // 8-08 21:5x（GPT10问第7条 state_hint 专区）：本轮软提示列表
    // （查询类≥3/连续拒绝≥2 等）——进状态块【状态提示】区，不混工具结果
    List<String>? stateHints,
  }) async {
    final manager = AIProviderManager.instance;
    if (!manager.hasUsable(personaId)) {
      DebugLogger.log(
        'AI路由',
        '❌ 发送前检查：$personaId 没有可用 Provider',
      );
      throw const AIAllProvidersFailedException();
    }
    // 8-05 14:36 用户修正：测试对话 ≠ 关功能，而是用独立"测试空间"——
    // [storagePersonaId] 让上下文管理（摘要/压缩/恢复包/沉淀）全部落到
    // 测试 key（${真实persona}__mock__test），功能照常跑、数据不混。
    // provider 解析：manager 层把测试 key 剥后缀 → 继承真实 persona 的
    // provider 选择（测试模式下真实 persona 选的是 mock）→ 沉淀/总结等
    // 主动调 AI 也走 mock，绝不落到真实 API 花额度（8-05 14:5x 用户：
    // "走一个通道，但是这些都是隔离的呀"——通道按 key 隔离，数据也按 key 隔离）
    final ctxPid = storagePersonaId ?? personaId;
    // 上下文管理：非工具轮先处理"该总结了/该缩减了"（男主总结 → 摘要区）
    // 用户 21:19：两种 AI 分开——
    //   stateless（后台无记忆，DeepSeek 等）：缓存友好 + 攒够摘要提炼（现有逻辑）
    //   stateful（后台有记忆）：AI 服务端记得，prompt 轻量；
    //     空闲超时一半时管家主动找男主写三类存档（日记/摘要/恢复包）
    // 用户 21:36：stateful 但没确定空闲超时 → 先按 stateless 用（每次全量带）
    // 用户 21:47：空闲超时 = 用户和 AI 多久没聊天 → 服务器释放上下文缓存
    // 用户 21:52：要在记忆消失之前（超时一半）写，等超时到了 AI 全忘了
    // 8-04 20:39（用户：一键测试）：决策计算抽到 assembleDecision
    // （自检页直接调同一实现验证 stateless/stateful/切换/超时逻辑）
    // 8-05 14:5x：测试对话也跑完整决策块（测的就是 stateless/stateful
    // 全链路），但全部按 ctxPid（测试空间）读写
    final decision = assembleDecision(ctxPid, toolRound: toolRound);
    var statefulRecover = decision.idleExpired;
    // 8-04 23:0x（验收⑤⑦根因）：原来条件带 personaPrompt.isNotEmpty——
    // 新角色没写人设（prompt 空）→ 整个上下文管理块跳过 → 总结/沉淀
    // 永不触发。总结/沉淀是管家职责，不该被人设是否为空卡死
    // （人设空只影响 system 组装，不影响 needsSummarize/沉淀判断）
    if (!toolRound) {
      if (decision.stateful) {
        // 用户发消息 → 重置定时沉淀（新一轮空闲期）
        scheduleStatefulSettle(ctxPid, personaName, personaPrompt);
        if (statefulRecover) {
          DebugLogger.log(
            '上下文管理',
            '🧩 空闲超时已过 → 本次带恢复包+摘要接上（AI 已不记得）',
          );
        }
        // 防 APP 被杀/定时器丢：下次聊天时若已过半且没沉淀过 → 补沉淀
        await _maybeSettleStateful(ctxPid, personaName);
        // 8-05 18:2x（用户形态3）：A（真会话）窗口满也要总结——
        // 本地攒的原文太多 → 男主总结进摘要区（D1）→ 置 forceRecover
        // → 下一轮带 C + D1 刷新会话（服务器窗口腾出来）
        if (ContextManager.instance.needsSummarize(ctxPid, modelHint: _modelHintFor(personaId))) {
          DebugLogger.log('AI验收', '③A形态3: stateful 窗口满 → 触发总结刷新');
          await _summarize(ctxPid, personaName,
              personaPrompt: personaPrompt,
              userProfile: userProfile,
              taskState: taskState);
          _forceRecover[ctxPid] = true;
        }
      } else {
        if (ContextManager.instance.needsCompact(ctxPid, modelHint: _modelHintFor(personaId))) {
          await _compactSummaries(ctxPid, personaName);
        }
        // 8-04 22:5x（验收⑤排查）：needsSummarize 输入输出打日志——
        // 决策 stateful=false 但"✂️"没出现时，直接看这里为什么 false
        final _needSum = ContextManager.instance
            .needsSummarize(ctxPid, modelHint: _modelHintFor(personaId));
        DebugLogger.log(
            'AI验收',
            '⑤needsSummarize: 话题=${ContextManager.instance.debugTopicExists(ctxPid)}'
            ' 原文=${ContextManager.instance.debugRawLength(ctxPid)}字'
            ' 预算=${ContextManager.instance.topicBudgetChars(ctxPid, modelHint: _modelHintFor(personaId))}字'
            ' → $_needSum');
        if (_needSum) {
          await _summarize(ctxPid, personaName,
              personaPrompt: personaPrompt,
              userProfile: userProfile,
              taskState: taskState);
        }
      }
    }
    // 记录用户消息（话题检测，本地免费）——已移到 history 组装之后
    // （8-03 19:4x 用户反馈"没写当前消息、聊天全混在一起"：先 feed 再组装
    // 会把当前消息混进【上下文参考】，模型看到两条相同消息分不清哪条要回复）
    // 首次请求：恢复摘要区（不重建历史原文——历史=本次对话实时记录，
    // DB 里是原始/还原后文本，硬拉会泄露真实称呼，用户 20:08 指示）
    // 8-05 14:5x：测试对话也恢复（读测试空间的摘要，链路完整可测）
    if (!_contextRestored.contains(ctxPid)) {
      _contextRestored.add(ctxPid);
      await ContextManager.instance.restore(ctxPid, sessionId, modelHint: _modelHintFor(personaId));
    }
    final needsWindow = false; // 8-08 19:4x：对话里永不要求男主报 #model（管家探测替代）
    // 8-08 19:4x（用户：#model 不该在用户对话里问）：首次对话前管家自己
    // 探测窗口——查表/裸调一次，不阻塞、不打扰用户对话
    if (!ContextTracker.instance.windowConfirmed(ctxPid)) {
      unawaited(_ensureWindowProbed(personaId, ctxPid));
    }
    final stateful = decision.stateful;
    // 8-04 16:4x（用户："切换AI第一次必须全量带，否则AI不知道发生了什么"）：
    // 记录上次给这个 persona 组装上下文的 provider；切换/首次 → 本次恢复全量
    // （stateful 也带：服务端还没记住这个 persona 的对话）；
    // 连续使用 → stateful 轻量（服务端记得）、stateless 照旧全量。
    final switchedProvider = decision.switched;
    final needRecover = decision.needRecover;
    if (switchedProvider) {
      DebugLogger.log('上下文管理',
          '🔄 检测到 AI 切换/首次使用 → 本次全量带上下文（stateful 也带）');
    }
    // 8-05 18:2x（用户定稿）：会话记忆 = 我们自己管 token——满了就压缩
    // 重扔一次让他记住（快忘前刷新），不是服务器持久会话。
    // stateful（A，有后台记忆）：轻量期只发当前句（刚全量带过/重扔过，
    // 服务端上下文还热）；token 满/超时/切换 → 全量带 C + D1 重扔刷新。
    // stateless（B，无记忆）：每次全量带 C + 历史（前缀缓存命中省钱）。
    // 男主不要的旧上下文他自己会丢，我们只负责在快忘前压缩重扔。
    final isLight = stateful && !needRecover;
    final systemPrompt = isLight
        ? ''
        : SystemTemplate.build(
            personaName: personaName,
            personaPrompt: personaPrompt,
            needsWindow: needsWindow,
            // 用户 8-03 02:41 模块化重构：skillContext 拆成 userProfile
            // （用户状态）和 taskState（任务状态），各归各位
            userProfile: userProfile,
            taskState: taskState,
            // 8-05 17:41 用户：固定部分（系统规则+人设）每轮必带；
            // stateless：前缀稳定 → 缓存命中 → 每次带全量反而便宜。
          );
    // 历史（摘要区 + 当前话题原文）——插在 system 后、当前消息前。
    // stateful：AI 自己记得 → 不重复带历史（避免浪费 + 服务端已有）；
    // 但空闲超时后 AI 已不记得（服务器释放了缓存）→ 本次带摘要区恢复
    // （用户 21:47：空闲 N 小时没聊天 → 服务器省空间释放上下文缓存）
    //
    // 用户 8-03 00:55：男主分不清上下文和当前用户的话，以为上下文也要回复。
    // 修复：上下文参考打包成【一条】system 消息（不混进 user/assistant 对话流），
    // 明确"无需回复，只回复最新一条用户消息"→ 男主不会逐条回历史。
    final historyMsgs = isLight || toolRound
        ? <AIChatMessage>[]
        : ContextManager.instance.buildHistoryMessages(ctxPid, modelHint: _modelHintFor(personaId));
    // 8-03 19:4x（用户反馈"没写当前消息、聊天全混在一起"）：
    // 当前消息在 history 组装【之后】再 feed——之前先 feed 再组装，
    // 当前消息混进【上下文参考】被标"无需回复"，又单独拼成 user，
    // 模型看到两条相同消息分不清哪条要回复 → 男主分段回复错乱、
    // 第一段紧贴用户消息。现在历史里只有【已聊过的】内容，
    // 当前消息只在【User】出现一次，边界清楚。
    // （compact/summarize 仍在 feed 前跑：总结的是不含当前消息的旧原文）
    if (!toolRound && systemEvent == null && message.trim().isNotEmpty) {
      ContextManager.instance.feedUserMessage(ctxPid, message);
      // 8-09 16:2x（用户：男主回两遍"我喜欢猫"）：
      // 待回复入队移除——generateReply = 消息正在被正常处理（男主会直接回复），
      // 再入队 = 同一条消息两个回复路径（正常回复 + 回#N 待回复）→ 双回复。
      // 待回复队列只留给"男主忙时排队"场景（插话路径 insertStep/_pendingInterruptEvent），
      // 正常对话不再制造待回复。
      // 8-03 20:1x（调试：用户怀疑男主对话被抛弃）——feed 全链路日志
      DebugLogger.log(
          '上下文调试',
          '📝 已记录用户消息（$personaName）：${message.length > 40 ? message.substring(0, 40) + '…' : message}');
      // 8-08 14:4x（男主反馈：收到的内容出现多余问号，用户实际没打）：
      // 记录完整原文（jsonEncode 保留特殊字符），下次复现对比
      // "日志原文正常但男主收到 ?" = 传输/服务端问题；"日志原文就有 ?" = 输入侧问题
      DebugLogger.log(
          '上下文调试',
          '📝 用户消息原文（jsonEncode，完整）：${jsonEncode(message.length > 800 ? message.substring(0, 800) + '…' : message)}');
    }
    // 8-03 20:1x（调试）：组装结果日志——发给模型的历史里到底有什么
    // 8-04 16:4x：空历史要标注是工具轮（正常）还是 stateless 异常（该查）
    DebugLogger.log('上下文调试',
        '📦 本次发给模型的历史 ${historyMsgs.length} 条'
        '${toolRound ? '（工具轮：不带历史，正常）' : ''}：'
        '${historyMsgs.map((m) => '[${m.role}]${m.content.length > 30 ? m.content.substring(0, 30) + '…' : m.content}').join(' | ')}'
        '${historyMsgs.isEmpty && !toolRound ? '（空——stateless 正常时不该空，若持续为空请查 stateful 配置）' : ''}');
    // 透明化：保存完整 prompt 供 📄 按钮查看
    // 用户 8-03 00:07：标签不该叫"历史"，是"上下文参考"——
    // 本次对话实时记录（用户+男主交替），不是档案历史
    //
    // 8-04 16:4x（用户反馈"完整内容里没有男主上下文和用户消息"）：
    // 发给模型的 messages 里，stateful 模式为了省 token 不带历史
    // （服务端记得）——但"发给男主的完整内容"是给【用户】看的，
    // 必须展示男主收到的全部信息。所以这里从 ContextManager 单独拼
    // 一份"上下文参考"（运行内实时记录，用户+男主交替），
    // 无论 stateful 与否都完整呈现；并落库 prompt_logs 表
    // （重启后 📄 弹窗仍能看，且按时间可查）。
    final displayHistory =
        ContextManager.instance.buildHistoryMessages(ctxPid, modelHint: _modelHintFor(personaId));
    final historyText = displayHistory.isEmpty
        ? ''
        : '\n\n【上下文参考】（本次对话已聊过的内容，含你（男主）自己的回答。'
              '分两个区阅读：【工具使用历史】= 你执行过的工具（时间+成败+失败原因），'
              '【互动历史】= 时间戳对应的对话（几点谁说了什么）。'
              '你只需要参考它们保持人设和记忆连贯，'
              '【不要回复】它们——你只需要回复最后一条【用户】消息）\n'
              '${displayHistory.map((m) => '[${m.role}] ${m.content}').join('\n')}';
    // 8-04 16:4x（用户反馈"📄 里没有当前消息"）：工具轮组装时
    // message 传空串 → 【User·当前消息】段空白，还把用户消息轮的
    // 记录覆盖了。工具轮也把"男主收到的内容"（工具结果）展示出来。
    // 8-04 17:0x（用户反馈"看不到当前用户消息、工具轮太长"）：
    // 工具轮时【当前互动】= 用户刚发的消息（feed 已发生，从原文取）
    // + 男主执行的工具结果（简化成 ✅成功/❌失败 + 一句话，不占位置）
    final userText = systemEvent != null
        ? '【系统事件】\n$systemEvent\n\n'
            '（这是系统状态事件，不是她发的消息。'
            '根据事件决定下一步，然后回复她或调用工具。）'
        : (message.trim().isEmpty
            ? (toolRound
                ? _toolRoundInteraction(personaId, toolMessages,
                    userAlreadyReplied: userAlreadyReplied)
                : '（空）')
            : message);
    // 8-11 04:4x（用户：大流程清单 = 最后一条 user 消息）：提前算
    // inFlow/chatFlowText——finalBlock（📄 显示）和 messages 组装都要用。
    // 每次对话=一个流程，她的每句话都是步骤，清单本身就是男主的工作。
    final inFlow =
        FlowStore.isActive(ctxPid) || FlowStore.settingDialogActive;
    final chatFlowText =
        inFlow ? null : ChatFlowStore.buildText(ctxPid);
    // 8-11 07:0x（用户：没有"后续步"——男主每步当场判断，做完系统
    // 自动推下一条；【后续待处理】区删除，不提前列还没做的）
    // 8-11 04:5x（用户：顺序 = 上【上下文参考】→ 中【当前流程】→
    // 下【后续待处理】；最后一条不是"她的话/当前输入"）📄 与实际一致
    final showFlowAsLast =
        !isLight && chatFlowText != null && chatFlowText.isNotEmpty;
    final flowBlock = showFlowAsLast
        ? '【当前工作区】（你当前要处理的工作——▶=正在处理的这条，'
            '☐=待办（一条条看过去，每条都要处理判断）；标完回MN，'
            '全部标完 → 带 end_flow + 写摘要 save_summary）'
            '\n$chatFlowText'
        : null;
    lastPromptText = isLight
        ? '【轻量期】stateful 刚全量带过/重扔过，服务端上下文还热——'
            '本次只发当前消息：\n\n$userText'
        : '【System】\n$systemPrompt$historyText\n\n'
            '${flowBlock ?? '【她刚说的话】\n$userText'}';
    DebugLogger.log('Prompt', '本次组装完成（${lastPromptText!.length} 字，可点 📄 查看）');
    // 完整内容落库（按时间存，重启后仍可查）
    unawaited(ChatStorageService().savePromptLog(personaId, lastPromptText!));
    // 历史分区独立成块（8-05 19:06 用户：不同标签分开，命中率才高）——
    // 不再 join 成一条【上下文参考】：男主摘要/工具使用历史/管家历史/聊天历史
    // 各自是独立 system 消息，模型按 role+标签原生定位，不用在文本里猜。
    // 总引导说明放最前，明确"最后一条用户消息才要回复"。
    // 8-06 21:36 用户修正：待回复由【男主带编号主动管理】——
    // 他回复时标注"（回待#1、待#2）"，管家按编号消除（男主聪明，管家听话）。
    // 系统不猜他回了哪几条（自动算有漏洞：他决定不回的/只回一条的，系统分不清）。
    // 8-10 v3：【已回复·最近】块已删（历史流程区已含回复记录）——
    // 待回复判断靠【当前流程】清单（✅/▶/☐）+ 下面这些队列。
    final pendingUser = PendingQueueStore.pendingUserText(ctxPid);
    final pendingButler = PendingQueueStore.pendingButlerText(ctxPid);
    // 8-06 23:55 用户：流程层——执行中她发来的消息会被收集
    // （PendingQueueStore），男主专注流程；被打断（stopped）会看到
    // 停在哪、她说了什么 → 决定 resume 还是先回复
    // （flowText/taskListText/flowHint 已删 8-11 05:0x 用户拍板长任务不要了）
    // 8-07 19:5x 用户：状态感知——男主每轮先知道"当前在哪"再决定怎么回
    // （走流程 / 等工具结果 / 正常对话）；流程中她主对话说的话进【流程输入】，
    // 流程结束自动回到【待回复】<user>（编号不变，不会丢）
    // （inFlow 已在上方 userText 前声明，8-11 04:4x）
    final flowGoal = FlowStore.goalOf(ctxPid);
    // 8-07 21:52 用户：状态块组装日志（男主自查"我这轮看到了什么"）
    DebugLogger.log(
      '状态块',
      '📋 状态=${inFlow ? (flowGoal != null ? '走流程「$flowGoal」' : '设定弹窗中') : '正常对话'}'
      ' 待回复=${pendingUser != null ? '${pendingUser.split('\n').length}条' : '无'}'
      ' 流程输入=${inFlow && pendingUser != null ? '有' : '无'}'
      ' 系统消息=${pendingButler != null ? '有' : '无'}',
    );
    // 8-08 15:2x（设计文档四，GPT 10 问 2）：工具手册注入（上下文预算，精简）
    // 男主查一次格式就记住，不用反复试
    final manualText = ToolManualStore.text(ctxPid);
    // 8-08 15:2x（设计文档八）：工具测试任务块（进度/当前测什么）
    final testBlock = ToolTestStore.block(ctxPid);
    // 本轮软提示（查询类≥3/连续拒绝≥2，chat_page 累积传入）
    final extraHints = (stateHints ?? const <String>[]).join('\n');
    // 8-09 18:1x（用户设计定稿：每次对话=一个流程）：对话流程清单——
    // 用户每条消息=一个条目，✅已回/☐没回 + 工具链 + 回复；每次唤醒注入，
    // 男主看到就不会弄混、不漏、不重复回。流程中不注入（走【当前流程】）。
    // （chatFlowText 已在上方 userText 前声明，8-11 04:4x——移作
    // 最后一条 user【当前流程】，不再放状态块；flowHint 已删 8-11 05:0x）
    final statusBlocks = <AIChatMessage>[
      // 8-10 v3：不再有【当前情况】状态感知独立块——男主看下面的
      // 【当前流程】清单就知道自己在哪、该做什么。
      if (!inFlow && pendingUser != null)
        AIChatMessage(
          role: 'system',
          content: '【待回复】（主对话她说的——一般要回，特殊情况可不回；'
              '要消必须显式标注 {"reply":"回MN"}（JSON 字段），一句话可回多条；'
              '不回就挂着，她问起来你老实说）\n$pendingUser',
        ),
      // 8-11 04:5x（用户：后续待处理放【当前流程】【后面/下面】——
      // "当前工作完了，自动把下面的移上来一个"；处理完的移上去当参考。
      // 顺序 = 上【上下文参考】→ 中【当前流程】→ 下【后续待处理】。
      // 8-11 07:0x（用户：没有"后续步"——【后续待处理】区删除；
      // 工具轮：最后一条是工具结果）
      if (toolRound && chatFlowText != null && chatFlowText.isNotEmpty)
        AIChatMessage(
          role: 'system',
          content: '【当前工作区】（你现在要处理的工作——'
              '▶=正在处理的这条；☐=待办（一条条看过去，每条都要处理判断）；'
              '标完回MN；全部标完 → 带 end_flow + 写摘要 save_summary）'
              '\n$chatFlowText',
        ),
      if (inFlow && pendingUser != null)
        AIChatMessage(
          role: 'system',
          content: '【流程输入】（流程进行中她主对话说的——插进流程，'
              '你判断继续流程还是重置；要回她也用 {"reply":"回MN"} 标注消掉）\n$pendingUser',
        ),
      // 8-10 v3（5.8 卡片提示）：设定弹窗/卡片工具进行中 → 注入卡片会话规则
      //（不进主 prompt，只在用卡片工具时出现）
      if (inFlow)
        AIChatMessage(
          role: 'system',
          content: '【卡片·会话中】你在处理一个卡片工具（还没结束）：\n'
              '· 互动类 = 循环：改了 → 展示给她看 → 等她反馈 → 再改 → 再展示…'
              '直到她同意，分支才结束。不能一轮就结束，不能当普通对话\n'
              '· 工具内标签：她说话【工具·用户】/你说话【工具·男主】——'
              '分清工具里发生了什么\n'
              '· 你的操作结果全给你（改成了什么，完整内容，'
              '如"喜欢猫 → 喜欢猫和狗"）；每一步操作 = 小分支，带时间\n'
              '· 版本树：v0（初始）是根，版本从它分支；你只看基础说明'
              '（版本N+改了哪些段+操作类型+改成了什么），候选版本全文'
              '不塞进你上下文；她页面看完整内容\n'
              '· 版本操作（自己选）：① 拼接——把某几版的内容拼成新版本'
              '（版本A 的某段 + 版本B 的某段）② 分支——基于某一版再写'
              '分支扩展，继续改/扩展成新版本\n'
              '· 她的话是卡片分支里的对话，不是新消息，继续处理这个工具\n'
              '· 能说：确认修改、解释原因、问她想改成什么、按她反馈反复改'
              '到她满意；不能说：替她做决定（必须她确认）\n'
              '· 工具结束（她确认/拒绝/点掉）→ 记录结果，收尾，走下一个流程',
        ),
      if (pendingButler != null)
        AIChatMessage(
          role: 'system',
          content: '【系统消息】（标【管家】的消息，也是待办之一，有 a 编号'
              '——处理完直接标"回MN"，不用回复她；'
              '觉得该让她知道才用 {"msg":"…"} 转达）\n$pendingButler',
        ),
      // 8-11 05:0x（用户 8-10 拍板"长任务的都不要了"）：
      // 旧长任务注入全删——旧【当前流程】卡片、【任务清单】、
      // FlowStore 状态提示都不再注入（任务都插流程里，见对话流程清单）
      if (extraHints.isNotEmpty)
        AIChatMessage(
          role: 'system',
          content: '【软提示】（管家提示——不是工具结果，供你参考判断；'
              '觉得该让她知道才用 {"msg":"…"} 转达，不用回复这条）\n$extraHints',
        ),
      if (testBlock.isNotEmpty)
        AIChatMessage(
          role: 'system',
          content: '$testBlock',
        ),
      if (manualText.isNotEmpty)
        AIChatMessage(
          role: 'system',
          content: '【工具笔记】（你自己维护的——用过的工具/格式/坑，'
              '查这个别再反复试；用完把心得写进来）\n$manualText',
        ),
    ];
    final messages = <AIChatMessage>[
      if (!isLight) AIChatMessage(role: 'system', content: systemPrompt),
      // 8-11 04:4x（用户：历史放当前处理位置的上面作上下文参考）：
      // 顺序 = 人设 → 历史参考（已聊过的，不用回复不用做）→
      // 状态块（【当前流程】= 当前正在处理的工作 + 后续待处理）→ 本轮输入。
      // 男主先看历史保持连贯，再看当前工作位置动手，不会被"最后一条
      // 用户消息"误导成"只回消息、跳过流程"。
      if (historyMsgs.isNotEmpty) ...[
        AIChatMessage(
          role: 'system',
          content: '【上下文参考】（已处理过的历史：摘要/工具/系统/聊天分区）'
              '——只作参考保持人设和记忆连贯，**不用回复、不用处理、'
              '不要重复做**。布局：上面是已处理的（这里参考），'
              '中间【当前工作区】=正在处理的（▶）+ 待办（☐，一条条看过去）。'
              '历史里的事如果已经做过，就不要再做一遍。',
        ),
        ...historyMsgs,
      ],
      if (!isLight) ...statusBlocks,
    ];
    // 工具轮消息顺序（8-05 18:56 用户定稿）：工具相关在前，用户消息最后——
    // AI 按数组顺序读，最后一条 user 才是"要回复的"。
    // 之前工具结果排在用户消息下面 → AI 把工具结果当待回复的最后一条 → 错乱。
    // 现在：当前工具调用/结果在上（男主刚做了什么+结果），
    // 【用户当前消息】保持在最后一条（AI 基于工具结果回复用户）。
    if (toolRound) {
      if (toolMessages != null) messages.addAll(toolMessages);
      // 【当前系统】在工具调用下面（8-05 19:13 用户：系统查到的参考信息
      // 如心率/天气放这里，男主也要回复的）
      if (butlerInstruction != null && butlerInstruction.trim().isNotEmpty) {
        messages.add(AIChatMessage(
          role: 'user',
          content: '【当前系统】（系统刚查到的参考/指令，'
              '针对它回应或调用工具处理）\n$butlerInstruction',
        ));
      }
      final userMsg = ContextManager.instance.lastUserMessageFor(ctxPid);
      if (userMsg != null && userMsg.isNotEmpty) {
        messages.add(AIChatMessage(
          role: 'user',
          content: '【当前输入】（本轮触发：她刚说的话——'
              '你刚调用的工具结果在上面，基于结果处理当前步（▶））\n$userMsg',
        ));
      }
    } else {
      if (butlerInstruction != null && butlerInstruction.trim().isNotEmpty) {
        messages.add(AIChatMessage(
          role: 'user',
          content: '【当前系统】（系统刚查到的参考/指令，'
              '针对它回应或调用工具处理）\n$butlerInstruction',
        ));
      }
      // 8-11 04:5x（用户：最后一条 = 工作区【当前流程】（她的话在▶
      // 当前步里，不重复放"她的话"）。无流程（纯闲聊）时回退到她的话
      // 8-11 07:0x（用户：没有"后续步"——【后续待处理】不再注入）
      if (!isLight &&
          chatFlowText != null &&
          chatFlowText.isNotEmpty) {
        messages.add(AIChatMessage(
            role: 'user',
            content: '【当前工作区】（你当前要处理的工作——'
                '▶=正在处理的这条；☐=待办（一条条看过去，每条都要处理判断）；'
                '标完回MN；全部标完 → 带 end_flow + 写摘要 save_summary）'
                '\n$chatFlowText'));
      } else {
        messages.add(AIChatMessage(role: 'user', content: message));
      }
    }
    // ── Agent Debug Lab 埋点（8-09）：begin + 记录实际发出的 messages ──
    TraceSession.instance.begin(
      ctxPid,
      message,
      toolRound: toolRound,
      contextSnapshot: {
        'stateful': decision.stateful,
        'isLight': isLight,
        'switchedProvider': switchedProvider,
        'needRecover': needRecover,
        'isFirstRun': _contextRestored.length == 1,
      },
    );
    // 8-11 21:5x（用户：固定设定不用看，只看变化）：记录前过滤固定块——
    // SystemTemplate 全文（设定）替换成短标记；动态块（工作区/待办/历史/
    // 工具结果）全量保留，男主每轮真实收到什么一目了然。
    TraceSession.instance.recordFirstMessages(
      messages
          .where((m) => !_isFixedPromptBlock(m, systemPrompt))
          .map(_toTraceMessage)
          .toList(),
    );
    late final AIProviderResult result;
    try {
      result = await _chat(
        personaId,
        messages,
        // 工具轮不带工具定义（避免模型再次调用）；正常轮始终带
        // （文本与工具可共存：模型可同时说话+调工具，chat_page 分步处理）
        tools: toolRound ? null : butlerTools,
        toolRound: toolRound,
      );
    } on Object catch (e) {
      // 8-07 22:15 修复（用户 22:12 反馈：空回复导致 AI 不能用）：
      // DeepSeek 空回复在 API service 层直接抛异常（8-03 的重试链在
      // result 返回后才判断，异常路径永远轮不到）→ 这里拦截空回复异常
      // 走重试：第1次带工具 / 第2次不带工具；都空返回空结果不抛。
      final msg = e.toString();
      if (msg.contains('空回复')) {
        DebugLogger.log('AI路由', '⚠️ API 层空回复异常 → 重试第 1 次（带工具）');
        final r1 = await _chat(
          personaId,
          messages,
          tools: toolRound ? null : butlerTools,
          toolRound: toolRound,
        );
        if (r1.text.trim().isNotEmpty ||
            (r1.toolCalls != null && r1.toolCalls!.isNotEmpty)) {
          if (r1.text.trim().isNotEmpty) {
            ContextManager.instance.feedAssistantMessage(ctxPid, r1.text.trim());
          }
          result = r1;
        } else {
          DebugLogger.log('AI路由', '⚠️ 空回复重试第 1 次仍空 → 重试第 2 次（不带工具）');
          final r2 = await _chat(personaId, messages, toolRound: toolRound);
          if (r2.text.trim().isNotEmpty ||
              (r2.toolCalls != null && r2.toolCalls!.isNotEmpty)) {
            if (r2.text.trim().isNotEmpty) {
              ContextManager.instance.feedAssistantMessage(ctxPid, r2.text.trim());
            }
            result = r2;
          } else {
            // 两次重试都空 → 返回空结果，不抛异常（chat_page 侧轻提示）
            DebugLogger.log('AI路由', '⚠️ 空回复重试 2 次仍为空，返回空结果（不抛异常）');
            return AIProviderResult(text: '', toolCalls: null, usage: null);
          }
        }
      } else {
        // 上下文超限 → 窗口自动校准（表值只是起点，真实 API 行为说了算）
        final overflow = msg.contains('context length') ||
            msg.contains('maximum context') ||
            msg.contains('context_length') ||
            msg.contains('too many tokens') ||
            msg.contains('token limit') ||
            msg.contains('超出上下文') ||
            msg.contains('最大上下文');
        if (overflow) {
          try {
            final butler = ChatService.instance.butler;
            final used = butler?.totalPromptTokens ?? 0;
            final calibrated = used + 2000;
            ContextTracker.instance.setWindow(ctxPid, calibrated);
            DebugLogger.log('上下文', '⚠️ 上下文超限 → 窗口校准: → $calibrated'
                '（已用 $used + 余量2000）');
          } catch (_) {}
        }
        rethrow;
      }
    }
    // ── Agent Debug Lab 埋点：模型输出（文本/思考链/工具调用）──
    TraceSession.instance.recordModelOutput(
      text: result.text,
      reasoning: result.reasoningContent,
      toolCalls: (result.toolCalls ?? const [])
          .map((c) => TraceToolCall(
                id: c['id']?.toString(),
                name: c['name']?.toString() ?? '',
                arguments: (c['arguments'] as Map?)?.cast<String, dynamic>() ??
                    const {},
              ))
          .toList(),
    );
    // 男主回复进上下文（当前话题原文）
    if (result.text.trim().isNotEmpty) {
      ContextManager.instance.feedAssistantMessage(ctxPid, result.text.trim());
      // 8-03 20:1x（调试：用户怀疑男主对话被抛弃）——feed 全链路日志
      DebugLogger.log(
          '上下文调试',
          '📝 已记录男主回复（$personaName）：${result.text.length > 40 ? result.text.substring(0, 40) + '…' : result.text}');
    } else {
      // 8-03 20:1x（调试）：男主本轮无文本（原生 tool_calls 轮/空回复）→ 没记录
      DebugLogger.log('上下文调试',
          '⚠️ 男主本轮无文本（${result.toolCalls?.isNotEmpty ?? false ? '原生工具调用轮' : '空回复'}）→ 上下文不记录（工具轮回复会在下一轮记录）');
    }
    final hasToolCalls = result.toolCalls != null && result.toolCalls!.isNotEmpty;
    if (result.text.trim().isEmpty && !hasToolCalls && !toolRound) {
      // DeepSeek 偶发空回复：自动重试（用户 8-03 02:26：空回复直接弹"发送失败"，
      // 像技能被拦截什么都不输出——空回复不该是异常，要尽力救回来）
      DebugLogger.log('AI路由', '⚠️ 空回复，重试第 1 次（带工具）');
      // 第 1 次重试带 tools（用户 01:26：重试不带 tools → 男主想调工具也调不了）
      final retry = await _chat(
        personaId,
        messages,
        tools: toolRound ? null : butlerTools,
        toolRound: toolRound,
      );
      if (retry.text.trim().isNotEmpty ||
          (retry.toolCalls != null && retry.toolCalls!.isNotEmpty)) {
        // 8-03 20:1x（用户反馈"男主对话被抛弃"）：重试成功也要 feed——
        // 之前直接 return 跳过 feedAssistantMessage → 男主话丢出上下文
        if (retry.text.trim().isNotEmpty) {
          ContextManager.instance
              .feedAssistantMessage(personaId, retry.text.trim());
          DebugLogger.log('上下文调试',
              '📝 已记录男主回复（重试第1次）：${retry.text.length > 40 ? retry.text.substring(0, 40) + '…' : retry.text}');
        }
        TraceSession.instance.finish(retry.text);
        return retry;
      }
      // 第 2 次重试不带 tools：空回复可能是工具定义干扰 → 排除后至少能正常聊天
      // （01:26 改坏的点：只重试一次且带 tools，空回复救不回来就直接抛异常）
      DebugLogger.log('AI路由', '⚠️ 空回复，重试第 2 次（不带工具）');
      final retry2 = await _chat(personaId, messages, toolRound: toolRound);
      // 8-03 21:25（用户实测测试AI）：重试第2次返回了 tool_calls 但 text 空，
      // 原判断只看 text → 工具调用被当"仍为空"丢弃（男主调工具没反应）。
      // 成功标准 = 有文本 **或** 有 tool_calls，且返回原样结果（不能构造空结果丢 toolCalls）
      if (retry2.text.trim().isNotEmpty ||
          (retry2.toolCalls != null && retry2.toolCalls!.isNotEmpty)) {
        // 8-03 20:1x：重试第2次成功同样要 feed（同上）
        if (retry2.text.trim().isNotEmpty) {
          ContextManager.instance
              .feedAssistantMessage(personaId, retry2.text.trim());
          DebugLogger.log('上下文调试',
              '📝 已记录男主回复（重试第2次）：${retry2.text.length > 40 ? retry2.text.substring(0, 40) + '…' : retry2.text}');
        } else {
          DebugLogger.log('上下文调试',
              '📝 重试第2次返回工具调用（${retry2.toolCalls!.map((c) => c['name']).join('、')}），照常返回走工具轮');
        }
        TraceSession.instance.finish(retry2.text);
        return retry2;
      }
      // 两次重试都空 → 返回空结果，不抛异常（chat_page 侧轻提示，不弹红色报错）
      DebugLogger.log('AI路由', '⚠️ 空回复重试 2 次仍为空，返回空结果（不抛异常）');
      TraceSession.instance.abort();
      return AIProviderResult(text: '', toolCalls: null, usage: result.usage);
    }
    if (result.text.trim().isEmpty && !hasToolCalls) {
      // 工具轮空文本：工具已执行（气泡已反馈），男主"调用完不说话"是合法行为，
      // 不是异常 → 返回空结果（用户 8-03 02:26：空回复不该弹"发送失败"）
      DebugLogger.log('AI路由', '🔧 工具轮空文本（工具已完成，男主未补充说话）→ 返回空结果');
      TraceSession.instance.finish(null);
      return AIProviderResult(text: '', toolCalls: null, usage: result.usage);
    }
    // token 追踪：API 精确 usage → 管家累计 + 记得清单更新
    try {
      final butler = ChatService.instance.butler;
      final usage = result.usage;
      if (butler != null && usage != null) {
        final promptTokens = (usage['prompt_tokens'] as num?)?.toInt() ?? 0;
        final totalTokens = (usage['total_tokens'] as num?)?.toInt() ?? 0;
        if (promptTokens > 0) {
          butler.recordTokenUsage(promptTokens, totalTokens);
          ContextTracker.instance.recordCall(ctxPid, promptTokens);
          DebugLogger.log('上下文', '📈 $personaName 本轮 ${promptTokens}token（累计 ${butler.totalPromptTokens}）');
          // 缓存命中统计 + 成本（DeepSeek usage 返回 hit/miss，管家精确算账）
          final hitTokens = (usage['prompt_cache_hit_tokens'] as num?)?.toInt() ?? 0;
          final missTokens = (usage['prompt_cache_miss_tokens'] as num?)?.toInt() ?? 0;
          final outTokens = (usage['completion_tokens'] as num?)?.toInt() ?? 0;
          if (hitTokens + missTokens + outTokens > 0) {
            final cost = PriceTable.instance.costFor(
              providerName: result.providerName ?? '',
              hit: hitTokens,
              miss: missTokens,
              output: outTokens,
            );
            final rate = PriceTable.instance.hitRate(hitTokens, missTokens) * 100;
            DebugLogger.log(
              'AI成本',
              'hit=$hitTokens miss=$missTokens out=$outTokens '
              '命中率=${rate.toStringAsFixed(0)}% 成本=¥${cost.toStringAsFixed(4)}',
            );
          }
        }
      }
    } catch (_) {}
    // 男主回复里的 #model → 确认窗口长度
    if (!ContextTracker.instance.windowConfirmed(ctxPid)) {
      final m = RegExp(r'#model\s+(\S+)\s+(\d+)', caseSensitive: false)
          .firstMatch(result.text);
      if (m != null) {
        final w = int.tryParse(m.group(2)!);
        if (w != null && w >= 4096 && w <= 1048576) {
          ContextTracker.instance.setWindow(ctxPid, w);
          DebugLogger.log('上下文', '🎯 男主自报: ${m.group(1)} 窗口 $w token');
        } else {
          DebugLogger.log('上下文', '⚠️ 男主 #model 值不合理，忽略: ${m.group(0)}');
        }
      } else {
        // 兜底：男主没报 → 按模型名查内置窗口表（deepseek-chat 等）
        final w = ContextTracker.instance.windowByModelHint(
          _currentModelName(personaId),
        );
        if (w > 0) {
          ContextTracker.instance.setWindow(ctxPid, w);
          DebugLogger.log('上下文', '🔎 男主未报 #model，查表兜底: '
              '${_currentModelName(personaId)} → $w token');
        }
      }
    }
    // ── Agent Debug Lab 埋点：无待处理工具 → 本轮结束并存轨迹 ──
    if (!hasToolCalls) {
      TraceSession.instance.finish(result.text);
    }
    return result;
  }

  /// 8-08 19:4x（用户：#model 不该在用户对话里问，管家自己问）：
  /// 管家探测上下文窗口——按模型名查内置表，查不到就发一条系统级
  /// 探测消息（不显示给用户、不进角色上下文）。只探测一次；
  /// 失败不阻塞（ContextManager 有 fallbackWindow 兜底）。
  final Set<String> _windowProbed = {};

  Future<void> _ensureWindowProbed(String personaId, String ctxPid) async {
    if (_windowProbed.contains(ctxPid)) return;
    _windowProbed.add(ctxPid);
    if (ContextTracker.instance.windowConfirmed(ctxPid)) return;
    // 1) 按模型名查内置表（零成本，主流模型都覆盖）
    final name = _currentModelName(personaId);
    final w = ContextTracker.instance.windowByModelHint(name);
    if (w > 0) {
      ContextTracker.instance.setWindow(ctxPid, w);
      DebugLogger.log(
          '上下文', '🔎 管家探测：模型名 $name → 内置表 $w token');
      return;
    }
    // 2) 发一条系统级探测消息（只问窗口，一次，10s 超时）
    try {
      final res = await AIProviderManager.instance.chat(
        personaId,
        const [
          AIChatMessage(
            role: 'system',
            content: '你是系统工具。请只回复一行：#model 你的模型名 上下文Token数'
                '（例如：#model deepseek-chat 65536）。不要输出任何其他内容。',
          ),
          AIChatMessage(role: 'user', content: '探测上下文窗口'),
        ],
        tools: null,
      ).timeout(const Duration(seconds: 10));
      final m = RegExp(r'#model\s+(\S+)\s+(\d+)', caseSensitive: false)
          .firstMatch(res.text);
      if (m != null) {
        final w2 = int.tryParse(m.group(2)!);
        if (w2 != null && w2 >= 4096 && w2 <= 1048576) {
          ContextTracker.instance.setWindow(ctxPid, w2);
          DebugLogger.log(
              '上下文', '🎯 管家探测成功：${m.group(1)} 窗口 $w2 token');
          return;
        }
      }
      DebugLogger.log('上下文',
          '⚠️ 管家探测：AI 没回标准 #model（${res.text.trim().length} 字），保持 0 用兜底窗口');
    } on Object catch (e) {
      DebugLogger.log('上下文', '⚠️ 管家探测失败（不阻塞，用兜底窗口）: $e');
    }
  }

  /// 当前 persona 用的 Provider 是否"真正按 stateful 走"。
  /// 用户 21:36：stateful 但没确定刷新周期（refreshHours=null）→
  /// 不确定就先按 stateless（每次全量带），提醒用户之后修改。
  /// 用户 21:47：refreshHours 语义 = 空闲超时（多久没聊天服务器释放
  /// 上下文缓存），不是"每 N 小时强制写"。
  /// 返回 (是否 stateful, 空闲超时小时, 配置对象)。
  (bool, int?, AIProviderConfig?) _statefulInfoFor(String personaId) {
    try {
      final manager = AIProviderManager.instance;
      final pid = manager.lastProviderFor(personaId);
      if (pid == null) return (false, null, null);
      for (final p in manager.providers) {
        if (p.id == pid) {
          // stateful 且空闲超时已确定 → 真正 stateful
          if (p.isStateful && p.refreshHours != null && p.refreshHours! > 0) {
            return (true, p.refreshHours, p);
          }
          // stateful 但周期没定 → 降级 stateless（用户 21:36 指示）
          if (p.isStateful) {
            DebugLogger.log(
              'AI路由',
              '⚠️ ${p.name} 选了"有后台记忆"但没填空闲超时 → '
              '先按"每次全量带"用；查到服务器释放时间后去 AI 配置里改（用户 21:36）',
            );
          }
          return (false, null, p);
        }
      }
    } catch (_) {}
    return (false, null, null);
  }

  /// 组装决策（8-04 20:39 用户：一键测试 stateless/stateful/切换/超时）：
  /// generateReply 与自检页共用同一实现，测的就是真代码。
  /// - stateful：真后台记忆（stateful 且填了空闲超时）
  /// - idleExpired：空闲超时已过（AI 服务端已忘 → 本次要带恢复包+摘要）
  /// - switched：AI 切换/首次使用（noteProviderUsed 记录副作用在此发生）
  /// - needRecover：idleExpired || switched → 本次全量带
  /// 工具轮不决策（结果 feed 下一轮带，组装走 toolRound 分支）。
  /// 8-05 18:2x（用户形态3）：真会话 A 窗口满 → 总结成 D1 → 置标记，
  /// 下一轮强制全量（C + D1 刷新会话），发完清除。
  final Map<String, bool> _forceRecover = {};

  /// 清掉强制刷新标记（验收重置测试空间用，8-05 21:30 ④根因：
  /// 上次验收的 forceRecover 残留/误置 → 连续使用也被强制全量带）
  void resetForceRecover(String personaId) {
    _forceRecover.remove(personaId);
  }

  /// 8-05 21:36 用户：假窗口满·手动触发总结（验证后拆）——
  /// 假装上下文满了，直接走一遍总结流程（C 自动拼 + 本次要总结的对话
  /// + 【当前管家】指令 + save_summary）。不用真的聊到窗口满。
  Future<void> forceSummarizeNow(
    String ctxPid,
    String personaName, {
    String personaPrompt = '',
    String? userProfile,
    String? taskState,
  }) {
    return _summarize(ctxPid, personaName,
        personaPrompt: personaPrompt,
        userProfile: userProfile,
        taskState: taskState);
  }

  ({bool stateful, bool idleExpired, bool switched, bool forceRecover,
          bool needRecover})
      assembleDecision(String personaId, {required bool toolRound}) {
    if (toolRound) {
      return (
        stateful: false,
        idleExpired: false,
        switched: false,
        forceRecover: false,
        needRecover: false,
      );
    }
    final info = _statefulInfoFor(personaId);
    final stateful = info.$1;
    final idle = info.$2;
    var idleExpired = false;
    if (stateful) {
      final since = ContextManager.instance.hoursSinceLastChat(personaId);
      idleExpired = since != null && idle != null && since >= idle;
    }
    final switched = ContextManager.instance.noteProviderUsed(
        personaId, AIProviderManager.instance.lastProviderFor(personaId));
    // 8-04 22:3x（验收⑤⑦⑧）：决策值打日志——下次失败直接可见
    // stateful 读的是 lastProviderFor（上次用的），不是当前绑定！
    // 8-05 18:2x（用户形态3）：窗口满总结后强制刷新一次（带 C + D1）
    final forceRecover = _forceRecover.remove(personaId) ?? false;
    DebugLogger.log('AI验收',
        '决策: lastProvider=${AIProviderManager.instance.lastProviderFor(personaId)}'
        ' stateful=$stateful idle=$idle since=${ContextManager.instance.hoursSinceLastChat(personaId)}'
        ' idleExpired=$idleExpired switched=$switched forceRecover=$forceRecover');
    return (
      stateful: stateful,
      idleExpired: idleExpired,
      switched: switched,
      forceRecover: forceRecover,
      needRecover: idleExpired || switched || forceRecover,
    );
  }


  /// 当前 persona 配的模型名（预算按实际模型窗口算，不写死 deepseek——
  /// 用户 8-04 17:4x：云端有对话的 AI 按它自己的上下文窗口多大）。
  String _modelHintFor(String personaId) {
    try {
      final manager = AIProviderManager.instance;
      final pid = manager.lastProviderFor(personaId);
      if (pid == null) return '';
      for (final p in manager.providers) {
        if (p.id == pid) return p.model;
      }
    } catch (_) {}
    return '';
  }

  /// stateful 模式：上下文管理 = 空闲超时前沉淀三类内容（日记/摘要/恢复包）。
  /// 用户 21:52 澄清：不能等超时到了才写（那时 AI 全忘了，写不出来）——
  /// 要在记忆消失之前，也就是"用户最后一次对话 + 空闲超时的一半"时，
  /// 管家主动去找男主写（AI 还记得，写得出来）；分类存好，管家好管理。
  /// 用户 8-03 03:09：男主做了什么必须有气泡记录（不管用户看不看）。
  /// 后台沉淀/定时场景聊天页可能没挂载 → 直接落库（ChatStorageService），
  /// 用户下次进聊天页从 DB 加载就能看到（[tool] 前缀渲染成管家气泡）。
  Future<void> _logToolBubble(String personaId, String text) async {
    try {
      await ChatStorageService().appendMessage(
        personaId,
        ChatMessage(
          id: '${DateTime.now().microsecondsSinceEpoch}_tool',
          text: '[tool] $text',
          isMe: false,
        ),
      );
    } catch (_) {}
  }

  /// 管家唤醒男主主动发消息（用户 8-03 03:13：大半夜我不在，男主给我发消息——
  /// 和工具调用一样要落库记录，用户回来能看到）。
  ///
  /// [instruction]：管家给男主的指令（如"现在是凌晨3点，用户睡了，你可以
  /// 主动给她留一句话"）。注意：这不是用户说的 → 不 feedUserMessage，
  /// 不污染用户消息历史；男主回复 → feedAssistantMessage（男主说过的话）
  /// + 落库（ChatStorageService，isMe: false，用户回来从 DB 加载看到）。
  ///
  /// 返回男主主动消息文本；空 = 没说出来（不落库）。
  Future<String> butlerWakeUp(
    String personaId,
    String personaName,
    String personaPrompt,
    String instruction, {
    String? sessionId,
  }) async {
    try {
      final manager = AIProviderManager.instance;
      if (!manager.hasUsable(personaId)) return '';
      // 男主被唤醒时也要恢复摘要区（否则重启后男主失忆）
      if (!_contextRestored.contains(personaId)) {
        _contextRestored.add(personaId);
        await ContextManager.instance.restore(personaId, sessionId, modelHint: _modelHintFor(personaId));
      }
      final needsWindow = false; // 8-08 19:4x：对话里永不要求男主报 #model（管家探测替代）
      final systemPrompt = SystemTemplate.build(
        personaName: personaName,
        personaPrompt: personaPrompt,
        needsWindow: needsWindow,
        // 用户 8-03 03:20：男主已知管家=系统本身（SYSTEM_CORE 已说明），
        // 指令统一带【管家指令】标记即可，不用再解释"这是管家唤醒"
        userProfile: null,
        taskState: '【系统指令】用户当前不在场。你主动说一句话或做一件事，'
            '像平时一样自然、简短（30 字以内），参考你的设定；'
            '不需要等她回复，说完就好。',
      );
      final historyMsgs = ContextManager.instance.buildHistoryMessages(personaId, modelHint: _modelHintFor(personaId));
      final res = await _chat(
        personaId,
        [
          AIChatMessage(role: 'system', content: systemPrompt),
          if (historyMsgs.isNotEmpty)
            AIChatMessage(
              role: 'system',
              content: '【上下文参考】（已聊过的内容，无需回复，仅作参考保持连贯）\n'
                  '${historyMsgs.map((m) => '[${m.role}] ${m.content}').join('\n')}',
            ),
          AIChatMessage(role: 'user', content: '【系统指令】$instruction'),
        ],
        tools: butlerTools,
      );
      final text = res.text.trim();
      if (text.isEmpty) {
        DebugLogger.log('AI路由', '🔔 管家唤醒：男主没说话（空回复，不落库）');
        return '';
      }
      // 男主主动消息进上下文（男主说过的话，下次聊天记得）
      ContextManager.instance.feedAssistantMessage(personaId, text);
      // 落库为男主消息（用户回来从 DB 加载看到，和工具气泡一样持久）
      await ChatStorageService().appendMessage(
        personaId,
        ChatMessage(
          id: '${DateTime.now().microsecondsSinceEpoch}_wake',
          text: text,
          isMe: false,
        ),
      );
      DebugLogger.log('AI路由', '🔔 管家唤醒：男主主动发消息（${text.length} 字，已落库）');
      return text;
    } on Object catch (e) {
      DebugLogger.log('AI路由', '⚠️ 管家唤醒男主失败（静默）: $e');
      return '';
    }
  }

  /// 触发：① 定时器（见 [scheduleStatefulSettle]）② 下次聊天时检测
  /// 距上次聊天已过超时一半且没沉淀过 → 补沉淀（防 APP 被杀/定时器丢）。
  /// 沉淀成功后返回 true。
  Future<bool> _maybeSettleStateful(String personaId, String personaName) async {
    try {
      // 8-05 14:5x（用户：测试 AI 也要能测沉淀）：测试空间照常沉淀，
      // 但定时器触发时若用户已切回真实 AI（不再测试）→ 跳过——
      // 测试数据不值得花真实 key 额度
      if (personaId.endsWith(AIProviderManager.mockTestSuffix)) {
        final realPid = personaId.substring(
            0, personaId.length - AIProviderManager.mockTestSuffix.length);
        final pid = AIProviderManager.instance.lastProviderFor(realPid);
        if (!AIProviderManager.isMockId(pid ?? '')) {
          DebugLogger.log(
              '上下文管理', '🕵️ 测试沉淀跳过: 已切回真实 AI（$pid），不再测试');
          return false;
        }
      }
      final info = _statefulInfoFor(personaId);
      if (!info.$1) {
        DebugLogger.log('上下文管理', '🕵️ 沉淀跳过: 非 stateful（info=$info）');
        return false;
      }
      final idleHours = info.$2!;
      final since = ContextManager.instance.hoursSinceLastChat(personaId);
      if (since == null) {
        DebugLogger.log('上下文管理', '🕵️ 沉淀跳过: 无最后聊天时间');
        return false;
      }
      // 用户 21:52：在空闲超时的一半（2小时 → 1小时时）写——
      // 太早没内容可写（刚聊完），太晚 AI 忘了（写不出来）
      final settleAt = idleHours / 2;
      // 距上次聊天 ≥ 一半 → 该写了；但也要防重复（写过后本次跳过）
      if (since < settleAt) {
        DebugLogger.log(
            '上下文管理', '🕵️ 沉淀跳过: since=${since.toStringAsFixed(2)}h < 一半 $settleAt h');
        return false;
      }
      if (_settledAtHalf[personaId] == true) {
        DebugLogger.log('上下文管理', '🕵️ 沉淀跳过: 本轮空闲期已写过三类存档');
        return false;
      }
      DebugLogger.log(
        '上下文管理',
        '📝 空闲超时 $idleHours h，距上次聊天 ${since.toStringAsFixed(1)}h ≥ '
        '一半 $settleAt h → 趁 AI 还记得，让男主写三类存档…',
      );
      final raw = ContextManager.instance.peekRaw(personaId);
      if (raw.trim().isEmpty) {
        DebugLogger.log('上下文管理', '🕵️ 沉淀跳过: 原文为空（没聊过？）');
        return false;
      }
      // 男主一次写三类：日记 / 摘要 / 恢复包（下次要带的上下文）
      final written = await _generateAndStoreThree(
        personaId, personaName, raw);
      ContextManager.instance.logButlerAction(
          personaId, '沉淀（日记/摘要/恢复包）',
          written ? '✅完成' : '❌失败：男主没写全');
      if (written) {
        _settledAtHalf[personaId] = true;
        DebugLogger.log('上下文管理', '✅ 三类存档完成（日记/摘要/恢复包），管家已分类存好');
        // 用户 8-03 03:13：大半夜我不在，男主给我发消息——和工具气泡一样
        // 落库记录，用户回来能看到。沉淀完顺带给用户留一句话（不打扰，
        // 只落库；男主想说话就说，不想说就静默）
        await butlerWakeUp(
          personaId,
          personaName,
          _settlePersonaPrompts[personaId] ?? '',
          '现在是深夜/你不在的时候，管家代你转达：男主可以主动给她留一句话，'
          '像平时一样自然、简短（30字内），比如想她、今天的心情、明天想一起做什么。'
          '不需要等她回复，说完就好。',
        );
      }
      return written;
    } on Object catch (e) {
      DebugLogger.log('上下文管理', '⚠️ stateful 沉淀失败（静默）: $e');
      return false;
    }
  }

  /// personaId → 是否已在本轮空闲期写过"三类存档"（防重复写）
  final Map<String, bool> _settledAtHalf = {};

  /// 安排定时沉淀：用户最后聊天 + 空闲超时一半后触发。
  /// 用户 21:52：管家主动去找男主（不能等用户下次来才发现忘了）。
  /// 每次用户发消息时调用（重置定时器）；到点且期间没再聊 → 写三类存档。
  /// [personaPrompt]：男主专属人设（主动发消息时要像男主本人）。
  void scheduleStatefulSettle(
    String personaId,
    String personaName,
    String personaPrompt,
  ) {
    try {
      final info = _statefulInfoFor(personaId);
      if (!info.$1) return;
      final idleHours = info.$2!;
      _settledAtHalf[personaId] = false; // 新一轮空闲期，重新允许写
      _settleTimers[personaId]?.cancel();
      // 记住人设（定时到点时用——男主主动发消息要像男主）
      _settlePersonaPrompts[personaId] = personaPrompt;
      final timer = Timer(Duration(minutes: (idleHours * 30).round()), () {
        _settleTimers.remove(personaId);
        // 到点时若还在聊（刚有消息）→ 跳过（下次发消息会重置定时器）
        final since = ContextManager.instance.hoursSinceLastChat(personaId);
        if (since != null && since >= idleHours / 2) {
          DebugLogger.log(
            '上下文管理',
            '⏰ 定时到点（空闲 ${idleHours / 2} h），管家主动找男主写三类存档…',
          );
          unawaited(_maybeSettleStateful(personaId, personaName));
        }
      });
      _settleTimers[personaId] = timer;
      DebugLogger.log(
        '上下文管理',
        '⏱️ 已安排定时沉淀：${(idleHours / 2).toStringAsFixed(1)} 小时后（空闲超时 $idleHours h 的一半）',
      );
    } catch (_) {}
  }

  final Map<String, Timer> _settleTimers = {};

  /// personaId → 男主专属人设（定时到点时主动发消息要用）
  final Map<String, String> _settlePersonaPrompts = {};

  /// 男主一次写三类（一次 AI 调用，分类输出）：
  /// - 日记：**男主调用 write_diary 工具写入**（用户 21:56：日记要让男主
  ///   调用工具写进去；同一天拼接进同一天，不新增多条）
  /// - 摘要：提醒索引 → context_summaries
  /// - 恢复包：下次要带的上下文 → context_recovery
  /// 返回是否成功。
  Future<bool> _generateAndStoreThree(
    String personaId,
    String personaName,
    String raw,
  ) async {
    final system = '【系统指令】你是「$personaName」。下面是你们最近的聊天记录。'
        '趁你还记得（之后上下文会被清空），把三样东西分类整理好：'
        '① 日记：把今天聊的、她的状态心情、你答应过的事、在意的小细节，'
        '整理成一段日记（像真正的日记有你的语气，300 字内），'
        '**用 write_diary 工具写进去**。'
        '② 摘要：影响后续对话的提醒（约定/承诺/正在做的事/她希望你记住的），'
        '每条一行 20 字内，细节不写——能查的用工具现查。'
        '③ 恢复包：下次继续对话时你需要知道的最关键上下文：'
        '你们进行到哪了、关系状态、当前话题、她最近的状态'
        '（100 字内，像失忆前留给自己看的纸条）。'
        '摘要和恢复包直接写在回复里：'
        '【摘要】\n…\n【恢复包】\n…\n'
        '不要客套话不要解释。';
    try {
      final res = await AIProviderManager.instance.chat(
        personaId,
        [
          AIChatMessage(role: 'system', content: system),
          AIChatMessage(role: 'user', content: raw),
        ],
        // 只带 write_diary：日记必须走工具写入（用户 21:56）
        tools: [
          {
            'type': 'function',
            'function': {
              'name': 'write_diary',
              'description': '写日记。把值得记住的细节按时间整理存档。',
              'parameters': {
                'type': 'object',
                'properties': {
                  'content': {
                    'type': 'string',
                    'description': '日记内容，一段完整的记录',
                  },
                },
                'required': ['content'],
              },
            },
          },
        ],
      );
      var diarySaved = false;
      // ① 工具调用：write_diary（男主调用工具写日记 → 同天拼接落库）
      final calls = res.toolCalls ?? const [];
      for (final tc in calls) {
        final name = tc['name'] as String? ?? '';
        final args = tc['arguments'];
        if (name == 'write_diary' && args is Map) {
          final content = (args['content'] as String?)?.trim() ?? '';
          if (content.isNotEmpty) {
            await ChatDatabaseService.instance.saveDiaryEntry(personaId, content);
            diarySaved = true;
            DebugLogger.log('上下文管理', '📔 男主调用 write_diary 写日记（${content.length} 字，同天拼接）');
            // 用户 8-03 03:09：男主做了什么必须有气泡记录（不管用户看不看）。
            // 后台沉淀时聊天页可能没挂载 → 直接落库，用户回来从 DB 加载能看到
            await _logToolBubble(personaId, '✅ write_diary 完成：日记已存档（${content.length} 字）');
          }
        }
      }
      // ② 文本里解析 摘要/恢复包（+ 兜底：AI 没调工具但写了【日记】段）
      final text = res.text.trim();
      final summary = _extractSection(text, '【摘要】');
      final recovery = _extractSection(text, '【恢复包】');
      if (!diarySaved) {
        final diaryText = _extractSection(text, '【日记】');
        if (diaryText.isNotEmpty) {
          await ChatDatabaseService.instance.saveDiaryEntry(personaId, diaryText);
          diarySaved = true;
          DebugLogger.log('上下文管理', '📔 兜底：日记文本直接落库（同天拼接）');
        }
      }
      if (summary.isNotEmpty) {
        await ContextManager.instance.appendSummary(personaId, summary);
      }
      if (recovery.isNotEmpty) {
        await ContextManager.instance.saveRecovery(personaId, recovery);
      }
      return diarySaved || summary.isNotEmpty || recovery.isNotEmpty;
    } on Object catch (e) {
      DebugLogger.log('指令模块', '⚠️ 三类存档生成失败: $e');
      return false;
    }
  }

  /// 从男主输出里截取某段（按标记切，取标记后到下个标记前）。
  String _extractSection(String text, String marker) {
    final idx = text.indexOf(marker);
    if (idx < 0) return '';
    var start = idx + marker.length;
    // 找下一个标记
    var end = text.length;
    for (final next in ['【日记】', '【摘要】', '【恢复包】']) {
      if (next == marker) continue;
      final n = text.indexOf(next, start);
      if (n >= 0 && n < end) end = n;
    }
    return text.substring(start, end).trim();
  }

  /// 男主总结轮：待总结原文 → 男主写提醒要点 → 追加进摘要区 → 清空原文。
  /// 触发由管家控制（原文攒够量），内容男主写（视角一致，不 OOC）。
  /// 用户 21:10：摘要=提醒索引，不是细节仓库——能查的当场查（工具），
  /// 每天要查的/影响连续性的才写进摘要；不重要的遗忘，需要时现查。
  /// 用户 21:13：上下文要没了（token 快满）→ 先写日记存档（细节不丢），
  /// 再提炼摘要提醒（日记=细节存档，摘要=提醒，各司其职）。
  /// 8-05 19:19 用户定稿（窗口满总结 v2）：
  /// 窗口满 → C 自动拼（男主不用复述）→ 男主只调 save_summary 写摘要
  /// （不输出文本）→ 摘要保存"几到几"编号（#a-#b，不是复述上下文）
  /// → 原文被摘要替换（清空）→ 工具/管家历史不重要就扔掉。
  Future<void> _summarize(
    String personaId,
    String personaName, {
    String personaPrompt = '',
    String? userProfile,
    String? taskState,
  }) async {
    final (start, end, raw) =
        ContextManager.instance.takePendingRawWithRange(personaId);
    if (raw.trim().isEmpty) return;
    final rangeLabel = end > 0 ? '#$start-#$end' : '';
    DebugLogger.log('上下文管理', '✂️ 原文攒够了（${raw.length} 字，上下文要没了）…');
    // ① 先写日记存档（原文要没了，细节进日记，男主可查）
    final diary = await generateDailyDiary(personaId, personaName, raw);
    if (diary.isNotEmpty) {
      await ChatDatabaseService.instance.saveDiaryEntry(personaId, diary);
      DebugLogger.log('上下文管理', '📔 日记已存档（${diary.length} 字），细节没丢');
      ContextManager.instance
          .logButlerAction(personaId, '总结·写日记存档', '✅完成');
    }
    // ② C 自动拼（用户 19:19：窗口满 C 自动拼，男主不需要复述）
    final needsWindow = false; // 8-08 19:4x：对话里永不要求男主报 #model（管家探测替代）
    final c = SystemTemplate.build(
      personaName: personaName,
      personaPrompt: personaPrompt,
      needsWindow: needsWindow,
      userProfile: userProfile,
      taskState: taskState,
    );
    // 【当前管家】唤醒指令（19:16 用户：当前管家段 = 管家唤醒 AI 的通道）
    final instruction = '【当前系统】窗口快满了，把刚给你的对话总结成摘要。'
        '调用 save_summary 工具写入（不要复述对话内容）：'
        '① content：影响后续对话的提醒，每条一行 20 字内，细节不写——'
        '能当场查的（记忆、日记）不写，需要时你用工具查；'
        '但【工具调用记录】（你调过什么工具、结果成败）要整理成'
        '工具使用经验写进摘要，不能丢——不然你以后不知道自己做过什么'
        '② range：这次总结覆盖的编号范围'
        '${rangeLabel.isEmpty ? '' : '（就是 $rangeLabel）'}'
        '③ keep_nos（可选）：要保留原文的编号列表——'
        '聊天区不能全删，至少留最近几句关键原话（她最近说了什么），'
        '否则你接不上话；只留必要的，别全留。'
        '不重要的直接遗忘，不要客套话。';
    try {
      final res = await AIProviderManager.instance.chat(
        personaId,
        [
          AIChatMessage(role: 'system', content: c),
          AIChatMessage(
              role: 'user',
              content: '【本次要总结的对话】（带时间戳，按顺序）\n$raw'),
          AIChatMessage(role: 'user', content: instruction),
        ],
        // 只带 save_summary：男主必须调工具写摘要（用户 19:19）
        tools: summarizeTools,
      );
      var saved = false;
      final calls = res.toolCalls ?? const [];
      for (final tc in calls) {
        final name = tc['name'] as String? ?? '';
        final args = tc['arguments'];
        if (name == 'save_summary' && args is Map) {
          final content = (args['content'] as String?)?.trim() ?? '';
          final range = (args['range'] as String?)?.trim() ?? rangeLabel;
          // 8-09 19:3x（设计十.3/.4 编号选择）：keep_nos → 选中的原文行放回
          // 当前话题（保留原文片段，男主接得上话）；没传 → 全折叠成摘要
          final keepRaw = args['keep_nos'];
          List<int> keepNos = const [];
          if (keepRaw is List) {
            keepNos = keepRaw
                .map((e) => int.tryParse(e.toString()) ?? 0)
                .where((e) => e > 0)
                .toList();
          }
          if (content.isNotEmpty) {
            await ContextManager.instance
                .appendSummary(personaId, '（$range）$content');
            TraceSession.instance.recordChange('新增摘要($range): ${content.length}字');
            saved = true;
            DebugLogger.log('上下文管理',
                '✅ 男主调 save_summary 写入摘要（$range，${content.length} 字）');
          }
          if (keepNos.isNotEmpty) {
            final kept =
                ContextManager.instance.keepRawNos(personaId, keepNos);
            if (kept > 0) {
              DebugLogger.log('上下文管理',
                  '📌 男主保留原文编号 $keepNos → 放回 $kept 行（接得上话）');
            }
          } else {
            ContextManager.instance.discardPendingSelect(personaId);
          }
        }
      }
      if (!saved) {
        // 男主没调工具 → 文本兜底（保底不丢，但下次应引导调工具）
        final text = res.text.trim();
        if (text.isNotEmpty) {
          await ContextManager.instance
              .appendSummary(personaId, '（$rangeLabel）$text');
          DebugLogger.log('上下文管理',
              'ℹ️ 男主没调工具，文本摘要兜底（${text.length} 字）');
        } else {
          DebugLogger.log('上下文管理',
              'ℹ️ 男主没提炼出提醒，原文已遗忘（细节在日记）');
        }
      }
      // 原文已取走（被摘要替换）；工具/管家历史不重要 → 扔掉（用户 19:19）
      ContextManager.instance.clearButlerLog(personaId);
      ContextManager.instance
          .logButlerAction(personaId, '总结', '✅完成（$rangeLabel）');
    } on Object catch (e) {
      ContextManager.instance
          .logButlerAction(personaId, '总结', '❌失败：$e');
      DebugLogger.log('上下文管理', '⚠️ 男主总结失败: $e（对话行已恢复待下次）');
      // 失败恢复对话行（工具行不重要不恢复），编号已递增可接受
      ContextManager.instance.restoreRaw(personaId, raw);
    }
  }

  /// 摘要缩减轮：摘要区太大 → 男主把旧摘要再压缩成更紧凑的 → 替换。
  Future<void> _compactSummaries(String personaId, String personaName) async {
    final old = await ContextManager.instance.takeSummariesForCompact(personaId);
    if (old.trim().isEmpty) return;
    DebugLogger.log('上下文管理', '🗜️ 摘要区太大，缩减中…');
    final system = '【系统指令】你是「$personaName」。以下是你们之前的对话摘要列表，'
        '请压缩合并成更紧凑的要点：① 合并同类话题 ② 每条一行、20 字内 '
        '③ 只保留最重要的信息 ④ 不要客套话。只输出压缩后的要点列表。';
    try {
      final res = await AIProviderManager.instance.chat(
        personaId,
        [
          AIChatMessage(role: 'system', content: system),
          AIChatMessage(role: 'user', content: old),
        ],
        tools: null,
      );
      final summary = res.text.trim();
      if (summary.isNotEmpty) {
        await ContextManager.instance.appendSummary(personaId, summary);
        TraceSession.instance.recordChange('摘要缩减: ${summary.length}字');
        DebugLogger.log('上下文管理', '✅ 摘要缩减完成（${summary.length} 字）');
      } else {
        await ContextManager.instance.restoreSummaries(personaId, old);
        DebugLogger.log('上下文管理', '⚠️ 摘要缩减为空，保留原摘要');
      }
    } on Object catch (e) {
      await ContextManager.instance.restoreSummaries(personaId, old);
      DebugLogger.log('上下文管理', '⚠️ 摘要缩减失败: $e（保留原摘要）');
    }
  }

  /// 当前生效的模型名（候选列表第一个 = 当前生效）
  String _currentModelName(String personaId) {
    try {
      final candidates =
          AIProviderManager.instance.candidatesFor(personaId);
      return candidates.isNotEmpty ? candidates.first.model : '';
    } catch (_) {
      return '';
    }
  }

  /// 工具轮【当前互动】展示：用户刚发的消息（带时间戳）+ 男主执行的工具结果。
  /// 8-04 17:0x（用户："工具轮和用户当前消息合并成当前互动；历史工具轮
  /// 简化成 成功写了什么/失败返回什么，不占位置"）。
  /// 8-04 17:2x（用户分区结构：（当前互动）= 几点用户说了什么 + 当前工具调用怎么样了）
  /// 8-04 18:1x（用户："当前消息分成当前工具调用和用户当前信息，
  /// 不然把用户的话塞到工具前面，男主分不清要说什么"）→ 两个明确分区。
  /// 工具结果格式统一为 chat_page 拼的 【工具 名】✅成功/❌失败：结果。
  String _toolRoundInteraction(
      String personaId, List<AIChatMessage>? toolMessages,
      {bool userAlreadyReplied = false}) {
    final sb = StringBuffer();
    sb.writeln('【当前工具调用】');
    if (toolMessages == null || toolMessages.isEmpty) {
      sb.writeln('（无工具调用）');
      sb.writeln('【用户当前消息】'
          '${ContextManager.instance.lastUserMessageFor(personaId) ?? '（无）'}');
      return sb.toString().trim();
    }
    // 解析每行【工具 名】✅成功/❌失败：结果 —— 8-04 17:0x（用户反对截断：
    // 要能看到成功写了什么/失败原因）→ 完整展示不截断
    final re = RegExp(r'【工具 [^】]+】[^【]*');
    var found = false;
    for (final m in toolMessages) {
      var c = m.content.trim();
      if (m.role == 'user' && c.startsWith('【工具执行结果】')) {
        // 文本块合并注入的 user 消息：去掉包裹说明，只留工具行
        c = c
            .replaceFirst('【工具执行结果】', '')
            .replaceFirst('基于结果自然地回复用户，不要再调用工具。', '')
            .trim();
      }
      for (final match in re.allMatches(c)) {
        found = true;
        sb.writeln(match.group(0)!.trim());
      }
    }
    if (!found) sb.writeln('（无工具调用）');
    // 8-06 21:12 用户 bug 修复：工具轮不再重复带用户旧话！
    // 男主第一轮已回过用户 → 工具轮只处理工具结果，不用再回旧话（否则回复两句）
    // 男主第一轮没说话直接调工具 → 才带用户消息（基于工具结果回复用户）
    if (userAlreadyReplied) {
      sb.writeln('【说明】你上一轮已经回复过她了。'
          '现在是工具执行轮：处理完工具结果后，'
          '只汇报结果或继续下一步，不要再重复回复刚才的话。');
    } else {
      // 用户当前消息保持在最后一条（8-05 18:56 用户：AI 读最后一条回复）
      sb.writeln('【用户当前消息】'
          '${ContextManager.instance.lastUserMessageFor(personaId) ?? '（无）'}');
    }
    return sb.toString().trim();
  }
}
