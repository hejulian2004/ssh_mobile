// System Admin Monitor Tab：组织多服务器监控和性能图表。

part of 'system_admin_screen.dart';

class _MonitorTab extends StatefulWidget {
  final AppStrings strings;
  final String? connectionId;
  final TabController tabController;
  final Future<void> Function() onStartMonitoring;

  const _MonitorTab({
    required this.strings,
    this.connectionId,
    required this.tabController,
    required this.onStartMonitoring,
  });

  @override
  State<_MonitorTab> createState() => _MonitorTabState();
}

class _MonitorTabState extends State<_MonitorTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _configExpanded = true;
  bool _wasRunning = false;
  bool _diskExpanded = true;
  int _serversPerChart = 1;
  final Set<String> _collapsedChartKeys = {};
  String? _chartItemsCacheKey;
  List<_MetricChartItem> _chartItemsCache = const [];

  AppStrings get strings => widget.strings;
  late PerformanceMonitorViewModel monitor;
  late List<ConnectionConfig> connections;

  List<ConnectionConfig> _getActiveConnections(
    PerformanceMonitorViewModel monitor,
    List<ConnectionConfig> connections,
  ) {
    return monitor.isRunning
        ? [
            for (final connection in connections)
              if (monitor.monitoringConnectionIds.contains(connection.id))
                connection,
          ]
        : [
            for (final connection in connections)
              if (monitor.selectedConnectionIds.contains(connection.id))
                connection,
          ];
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    monitor = context.read<PerformanceMonitorViewModel>();
    final directory = context
        .select<SystemAdminViewModel, List<ConnectionConfig>>(
          (vm) => vm.connections,
        );
    connections = widget.connectionId == null
        ? directory
        : [
            for (final connection in directory)
              if (connection.id == widget.connectionId) connection,
          ];

    return Column(
      children: [
        Selector<PerformanceMonitorViewModel, _MonitorConfigSnapshot>(
          selector: (_, monitor) => _MonitorConfigSnapshot.from(monitor),
          builder: (context, snapshot, _) {
            if (snapshot.isRunning && !_wasRunning) {
              _configExpanded = false;
            }
            _wasRunning = snapshot.isRunning;
            return _MonitorConfigPanelV2(
              strings: strings,
              monitor: monitor,
              serversPerChart: _serversPerChart,
              onStartMonitoring: widget.onStartMonitoring,
              expanded: _configExpanded,
              onToggle: () =>
                  setState(() => _configExpanded = !_configExpanded),
              onServersPerChartChanged: (value) {
                setState(() => _serversPerChart = value);
              },
              onCustomInterval: () => _showCustomDuration(
                title: _monitorText(strings, 'Interval', '刷新间隔'),
                initial: monitor.interval,
                onChanged: monitor.setInterval,
              ),
              onCustomWindow: () => _showCustomDuration(
                title: _monitorText(strings, 'Range', '时间范围'),
                initial: monitor.historyWindow,
                max: PerformanceMonitorService.maxRetention,
                onChanged: monitor.setHistoryWindow,
              ),
            );
          },
        ),
        Expanded(
          child:
              Selector<
                PerformanceMonitorViewModel,
                _MonitorPerformanceSnapshot
              >(
                selector: (_, monitor) =>
                    _MonitorPerformanceSnapshot.from(monitor, [
                      for (final connection in connections)
                        if (monitor.monitoringConnectionIds.contains(
                          connection.id,
                        ))
                          connection,
                    ]),
                builder: (context, _, _) => _buildPerformanceTab(context),
              ),
        ),
      ],
    );
  }

  Widget _buildPerformanceTab(BuildContext context) {
    final monitor = context.read<PerformanceMonitorViewModel>();
    final chartConnections = _getActiveConnections(monitor, connections);
    final monitoringConnections = [
      for (final connection in connections)
        if (monitor.monitoringConnectionIds.contains(connection.id)) connection,
    ];
    final samplesByConnection = {
      for (final connection in monitoringConnections)
        connection.id: monitor.visibleSamplesFor(connection.id),
    };
    final hasSamples = samplesByConnection.values.any((samples) {
      return samples.isNotEmpty;
    });

    if (!monitor.isRunning) {
      return _MonitorResponsiveEmptyState(
        strings: strings,
        message:
            [
              for (final connection in connections)
                if (monitor.selectedConnectionIds.contains(connection.id))
                  connection,
            ].isEmpty
            ? null
            : _monitorText(
                strings,
                'Stop monitoring before changing server selection.',
                '停止监控后可修改服务器选择。',
              ),
      );
    }
    if (monitoringConnections.isEmpty) {
      return _MonitorResponsiveEmptyState(
        strings: strings,
        message: _monitorText(
          strings,
          'No active monitoring servers.',
          '暂无处于监控中的服务器。',
        ),
      );
    }
    if (!hasSamples) {
      return AppSkeletonizer.zone(
        enabled: true,
        semanticsLabel: _monitorText(strings, 'Waiting for samples', '等待采样数据'),
        child: const _MonitorOverviewSkeleton(),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns = constraints.maxWidth >= 860;
        final chartItems = _metricChartItems(chartConnections);
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
          itemCount: chartItems.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return RepaintBoundary(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _MonitorOverviewPanel(
                    strings: strings,
                    connections: chartConnections,
                    monitor: monitor,
                    diskExpanded: _diskExpanded,
                    onDiskToggle: () =>
                        setState(() => _diskExpanded = !_diskExpanded),
                  ),
                ),
              );
            }
            final item = chartItems[index - 1];
            return RepaintBoundary(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _MetricChart(
                  metricKey: item.spec.key,
                  title: item.title,
                  unit: item.spec.unit,
                  connections: item.connections,
                  samplesByConnection: samplesByConnection,
                  chartHeight: twoColumns ? 178 : 168,
                  maxY: item.spec.maxY,
                  valueFor: item.spec.valueFor,
                  latestTextFor: item.spec.latestTextFor,
                  expanded: !_collapsedChartKeys.contains(item.key),
                  onToggle: () {
                    setState(() {
                      if (!_collapsedChartKeys.remove(item.key)) {
                        _collapsedChartKeys.add(item.key);
                      }
                    });
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }

  List<_MetricChartItem> _metricChartItems(
    List<ConnectionConfig> chartConnections,
  ) {
    final cacheKey = [
      strings.language.name,
      _serversPerChart,
      for (final connection in chartConnections) connection.id,
    ].join('|');
    if (_chartItemsCacheKey == cacheKey) {
      return _chartItemsCache;
    }
    final specs = _metricSpecs();
    final items = <_MetricChartItem>[];
    final groupSize = _serversPerChart.clamp(1, 99);
    for (final spec in specs) {
      for (var start = 0; start < chartConnections.length; start += groupSize) {
        final end = min(start + groupSize, chartConnections.length);
        final group = chartConnections.sublist(start, end);
        items.add(
          _MetricChartItem(
            key: '${spec.key}-$start',
            title: group.length == chartConnections.length
                ? spec.title
                : '${spec.title} ${start + 1}-${start + group.length}',
            spec: spec,
            connections: group,
          ),
        );
      }
    }
    _chartItemsCacheKey = cacheKey;
    _chartItemsCache = List.unmodifiable(items);
    return _chartItemsCache;
  }

  List<_MetricSpec> _metricSpecs() {
    return [
      _MetricSpec(
        key: 'cpu',
        title: 'CPU',
        unit: '%',
        maxY: 100,
        valueFor: (sample) => sample.cpuPercent,
        latestTextFor: (sample) => '${sample.cpuPercent.toStringAsFixed(1)}%',
      ),
      _MetricSpec(
        key: 'memory',
        title: _monitorText(strings, 'Memory', '内存'),
        unit: '%',
        maxY: 100,
        valueFor: (sample) => sample.memoryPercent,
        latestTextFor: (sample) =>
            '${sample.memoryPercent.toStringAsFixed(1)}%',
      ),
      _MetricSpec(
        key: 'disk',
        title: _monitorText(strings, 'Disk IO', '磁盘 IO'),
        unit: 'MB/s',
        valueFor: (sample) => sample.diskBytesPerSecond / 1024 / 1024,
        latestTextFor: (sample) =>
            '${_formatRate(sample.diskBytesPerSecond)}/s',
      ),
      _MetricSpec(
        key: 'network',
        title: _monitorText(strings, 'Network', '网络'),
        unit: 'MB/s',
        valueFor: (sample) => sample.networkBytesPerSecond / 1024 / 1024,
        latestTextFor: (sample) =>
            '${_formatRate(sample.networkBytesPerSecond)}/s',
      ),
    ];
  }

  Future<void> _showCustomDuration({
    required String title,
    required Duration initial,
    required ValueChanged<Duration> onChanged,
    Duration? max,
  }) async {
    final controller = TextEditingController(text: '${initial.inSeconds}');
    var unitSeconds = true;
    final duration = await showDialog<Duration>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text('${_monitorText(strings, 'Custom', '自定义')} $title'),
            content: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: title),
                  ),
                ),
                const SizedBox(width: 12),
                DropdownButton<bool>(
                  value: unitSeconds,
                  items: [
                    DropdownMenuItem(
                      value: true,
                      child: Text(_monitorText(strings, 'Seconds', '秒')),
                    ),
                    DropdownMenuItem(
                      value: false,
                      child: Text(_monitorText(strings, 'Minutes', '分钟')),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => unitSeconds = value);
                    }
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(strings.cancel),
              ),
              FilledButton(
                onPressed: () {
                  final value = int.tryParse(controller.text.trim());
                  if (value == null || value <= 0) return;
                  final next = unitSeconds
                      ? Duration(seconds: value)
                      : Duration(minutes: value);
                  Navigator.pop(ctx, max != null && next > max ? max : next);
                },
                child: Text(strings.save),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (duration != null) onChanged(duration);
  }

  String _formatRate(double bytesPerSecond) {
    if (bytesPerSecond >= 1024 * 1024) {
      return '${(bytesPerSecond / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (bytesPerSecond >= 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB';
    }
    return '${bytesPerSecond.toStringAsFixed(0)} B';
  }
}

class _MonitorOverviewSkeleton extends StatelessWidget {
  const _MonitorOverviewSkeleton();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
      children: [
        Container(
          height: 120,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.3,
            ),
            borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Bone(width: 140, height: 16),
              const SizedBox(height: 12),
              Row(
                children: const [
                  Expanded(child: Bone(width: double.infinity, height: 48)),
                  SizedBox(width: 12),
                  Expanded(child: Bone(width: double.infinity, height: 48)),
                ],
              ),
            ],
          ),
        ),
        for (var i = 0; i < 4; i++)
          Container(
            key: ValueKey('monitor-skeleton-chart-$i'),
            height: 180,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.3,
              ),
              borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: const [
                    Bone(width: 100, height: 16),
                    Bone(width: 60, height: 16),
                  ],
                ),
                const SizedBox(height: 16),
                const Expanded(
                  child: Bone(width: double.infinity, height: double.infinity),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
