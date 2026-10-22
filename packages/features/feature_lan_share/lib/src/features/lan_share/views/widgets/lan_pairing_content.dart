part of '../lan_pairing_screen.dart';

extension _LanPairingContent on _LanPairingScreenState {
  /// 构建配对 UI 和当前审批状态。

  Widget _buildPairingContent(BuildContext context) {
    final vm = context.watch<LanShareViewModel>();
    final settings = context.read<LanShareSettingsPort>();
    final strings = settings.strings;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.lanSharePinPairing),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: AppPageSurface(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: 24.0,
              vertical: 16.0,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Beautiful Pulsing Radar Animation
                SizedBox(
                  width: 220,
                  height: 220,
                  child: Stack(
                    alignment: Alignment.center,
                    children:
                        List.generate(3, (index) {
                          return AnimatedBuilder(
                            animation: _radarController,
                            builder: (context, child) {
                              final progress =
                                  (_radarController.value + index / 3) % 1.0;
                              return Container(
                                width: 100 + (progress * 120),
                                height: 100 + (progress * 120),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: colors.primary.withValues(
                                    alpha: (1.0 - progress) * 0.25,
                                  ),
                                ),
                              );
                            },
                          );
                        })..add(
                          Container(
                            width: 90,
                            height: 90,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: colors.primaryContainer,
                              boxShadow: [
                                BoxShadow(
                                  color: colors.primary.withValues(alpha: 0.3),
                                  blurRadius: 16,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Icon(
                              Icons.security_rounded,
                              size: 40,
                              color: colors.onPrimaryContainer,
                            ),
                          ),
                        ),
                  ),
                ),
                const SizedBox(height: 48),

                Text(
                  _isIncomingRequest ? '安全配对请求' : '准备连接至$_targetAlias',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _isIncomingRequest
                      ? '设备$_targetAlias请求与您配对连接…'
                      : '正在建立安全连接，请输入对方设备上显示的PIN码…',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                if (pairingDirectionHint(
                      _directionNotice,
                      english: strings.isEnglish,
                    )
                    case final hint?) ...[
                  const SizedBox(height: 12),
                  Text(
                    hint,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 20),

                // Local PIN display card
                Builder(
                  builder: (context) {
                    final isExpiring = _pinCountdown <= 10;
                    final countdownColor = isExpiring
                        ? colors.error
                        : colors.primary;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20.0,
                        vertical: 14.0,
                      ),
                      decoration: BoxDecoration(
                        color: isExpiring
                            ? colors.errorContainer.withValues(alpha: 0.25)
                            : colors.primaryContainer.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: countdownColor.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '本机PIN码',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: countdownColor.withValues(alpha: 0.75),
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.8,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _localPin,
                                style: theme.textTheme.headlineMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 10.0,
                                  color: countdownColor,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 20),
                          // Circular countdown indicator
                          GestureDetector(
                            onTap: _refreshLocalPin,
                            child: SizedBox(
                              width: 44,
                              height: 44,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  AppLoadingIndicator(
                                    value: _pinCountdown / 60.0,
                                    size: 44,
                                    strokeWidth: 3,
                                    backgroundColor: countdownColor.withValues(
                                      alpha: 0.15,
                                    ),
                                    color: countdownColor,
                                  ),
                                  Text(
                                    '$_pinCountdown',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: countdownColor,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 24),

                // Glassmorphic Style PIN Form Container
                Container(
                  padding: const EdgeInsets.all(24.0),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerLowest.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: colors.outlineVariant.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        strings.lanSharePinPrompt,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Custom 6-Digit PIN Field
                      TextField(
                        controller: _pinController,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          letterSpacing: 8.0,
                        ),
                        decoration: InputDecoration(
                          hintText: '••••••',
                          hintStyle: TextStyle(
                            color: colors.onSurfaceVariant.withValues(
                              alpha: 0.3,
                            ),
                            letterSpacing: 4.0,
                          ),
                          counterText: '',
                          errorText: _errorMessage,
                          errorMaxLines: 2,
                          filled: true,
                          fillColor: colors.surfaceContainer,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 16.0,
                            horizontal: 8.0,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        enabled: !_isLoading,
                      ),
                      const SizedBox(height: 24),

                      // Submit Button
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: colors.primary,
                            foregroundColor: colors.onPrimary,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: _isLoading
                              ? null
                              : () => _submitPin(vm, strings),
                          child: _isLoading
                              ? const AppLoadingIndicator(
                                  size: 24,
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                )
                              : const Text(
                                  '确认配对',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Cancel button
                TextButton(
                  onPressed: () => _terminatePairing(vm),
                  child: Text(
                    _isLoading ? strings.lanDeviceTerminate : strings.cancel,
                    style: TextStyle(
                      color: colors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
