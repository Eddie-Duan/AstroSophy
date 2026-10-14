import 'package:flutter/material.dart';

/// 全局配色。
///
/// 深蓝底是为了让星点在屏幕上不刺眼，也贴近真实观测时的环境；
/// 薄荷绿是主强调色，黄色留给「需要用户自己判断」的信息。
///
/// 单独放一个文件，是因为主界面和共享组件都要用——
/// 组件拆到独立库之后，带下划线的私有常量就跨不过去了。
const kBackground = Color(0xFF080E19);
const kPanel = Color(0xFF101A2A);
const kMint = Color(0xFF64D9BD);
