// ignore_for_file: prefer_initializing_formals
// Public named parameters intentionally initialize private ViewModel fields.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../services/background_service.dart';
import '../../../services/app_settings.dart';

class StartupViewModel extends ChangeNotifier {
  final AppSettings _appSettings;

  bool _checkingPowerStatus = false;
  bool _powerStatusChecked = false;
  bool _powerStatusCheckScheduled = false;
  bool _shouldShowPowerGuide = false;
  bool _isExempt = false;

  StartupViewModel({required AppSettings appSettings})
    : _appSettings = appSettings {
    _appSettings.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    _appSettings.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    notifyListeners();
  }

  // Getters
  bool get storageInitialized =>
      _appSettings.coreLoaded || _appSettings.initialized;
  bool get settingsInitialized =>
      _appSettings.coreLoaded || _appSettings.initialized;
  AppLanguage get language => _appSettings.language;

  bool get isAndroidTarget =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get checkingPowerStatus => _checkingPowerStatus;
  bool get powerStatusChecked =>
      _powerStatusChecked || _appSettings.powerGuideSeen;
  bool get powerStatusCheckScheduled => _powerStatusCheckScheduled;
  bool get shouldShowPowerGuide => _shouldShowPowerGuide;
  bool get isExempt => _isExempt;

  Future<void> checkPowerGuideStatus() async {
    if (_powerStatusChecked || _checkingPowerStatus) return;
    if (!isAndroidTarget) {
      _powerStatusChecked = true;
      _shouldShowPowerGuide = false;
      notifyListeners();
      return;
    }

    if (_appSettings.powerGuideSeen) {
      _powerStatusChecked = true;
      _shouldShowPowerGuide = false;
      notifyListeners();
      return;
    }

    _checkingPowerStatus = true;
    notifyListeners();

    bool exempt = false;
    try {
      exempt = await BackgroundServiceManager.isIgnoringBatteryOptimizations()
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      exempt = false;
    }

    _isExempt = exempt;
    _checkingPowerStatus = false;
    _powerStatusChecked = true;
    _shouldShowPowerGuide = !exempt;
    notifyListeners();
  }

  Future<void> refreshBatteryExemptionStatus() async {
    try {
      final exempt =
          await BackgroundServiceManager.isIgnoringBatteryOptimizations()
              .timeout(const Duration(seconds: 2));
      _isExempt = exempt;
      notifyListeners();
    } catch (_) {
      _isExempt = false;
      notifyListeners();
    }
  }

  Future<void> requestBatteryExemption() async {
    await BackgroundServiceManager.requestBatteryOptimizationExemption()
        .timeout(const Duration(seconds: 2), onTimeout: () {});
    await refreshBatteryExemptionStatus();
  }

  void openAppSettings() {
    BackgroundServiceManager.openAppSettings();
  }

  void enterAppForThisLaunch() {
    _shouldShowPowerGuide = false;
    notifyListeners();
  }

  Future<void> markPowerGuideSeen() async {
    await _appSettings.markPowerGuideSeen();
    enterAppForThisLaunch();
  }

  void schedulePowerGuideCheck(VoidCallback callback) {
    if (powerStatusChecked ||
        _checkingPowerStatus ||
        _powerStatusCheckScheduled) {
      return;
    }
    _powerStatusCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _powerStatusCheckScheduled = false;
      callback();
    });
  }
}
