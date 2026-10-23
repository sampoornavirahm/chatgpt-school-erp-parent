import 'dart:async';

import 'package:flutter/material.dart';
import 'package:school_erp_parents/firebase_options.dart';
import 'package:school_erp_mobile_shared/school_erp_mobile_shared.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(
    launchSchoolErpApp(
      role: MobileRole.parent,
      firebaseOptions: DefaultFirebaseOptions.currentPlatform,
    ),
  );
}
