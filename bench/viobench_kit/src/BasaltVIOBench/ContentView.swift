import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: BenchViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("画面") {
                    BenchPreview(
                        source: model.previewSource,
                        frame: model.previewFrame
                    )
                    .listRowInsets(EdgeInsets())
                    Text("显示层不进算法队列,不改像素格式、分辨率、帧率或时间戳")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("模式") {
                    Picker("引擎", selection: $model.selectedBackend) {
                        ForEach(BenchBackend.allCases) { backend in
                            Text(backend.displayName).tag(backend)
                        }
                    }
                    .disabled(model.isRunning)

                    Picker("实验", selection: $model.mode) {
                        ForEach(BenchMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .disabled(model.isRunning)

                    if !model.mode.isReplay {
                        Picker("时长", selection: $model.measurementSeconds) {
                            ForEach(LiveBenchmarkDuration.selectableSeconds, id: \.self) {
                                Text("\($0) 秒").tag($0)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.isRunning)
                        if let note = model.storageNote {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(note.hasPrefix("⚠") ? .orange : .secondary)
                        }
                    }

                    Text(model.plannedRunSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let conflict = model.modeBackendConflict {
                        Text(conflict)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    if model.mode == .replayDeviceRecording && model.selectedBackend != .arkit {
                        if model.recordings.isEmpty {
                            Text("还没有本机录制。先用 ARKit 臂跑一次「录制一次」。")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        } else {
                            Picker("录制", selection: Binding(
                                get: { model.datasetURL ?? model.recordings[0] },
                                set: { model.selectRecording($0) }
                            )) {
                                ForEach(model.recordings, id: \.self) { url in
                                    Text(url.lastPathComponent.replacingOccurrences(
                                        of: "run-", with: ""
                                    ).prefix(8) + "").tag(url)
                                }
                            }
                            .disabled(model.isRunning)
                        }
                    }

                    if model.mode.hasExternalGroundTruth && model.selectedBackend != .arkit {
                        Button("选择 EuRoC MH_01_easy 目录") {
                            model.requestDatasetImport()
                        }
                        .disabled(model.isRunning)
                        if let dataset = model.datasetLabel {
                            Text(dataset).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("冻结边界") {
                    row(
                        "算法",
                        "\(model.selectedBackend.displayName) \(model.selectedBackend.upstreamRevision.prefix(8))"
                    )
                    row(
                        "传感器",
                        model.selectedBackend == .arkit
                            ? "生产同配 ARKit 内部融合"
                            : (model.mode.hasExternalGroundTruth
                                ? "EuRoC cam0 752×480 · 数据集原始 IMU"
                                : "1920×1440@30Hz · 原始 IMU 100Hz")
                    )
                    row(
                        "Apple 位姿",
                        model.selectedBackend == .arkit ? "仅参考基线臂" : "未使用 ARKit"
                    )
                    row("功率", "不伪造 W；记录电量/CPU/热代理")
                    row("互斥", "一次仅运行一条臂；运行中禁止切换")
                }

                Section("运行") {
                    if model.isRunning {
                        Button("中止并保存收据", role: .destructive) { model.abort() }
                    } else {
                        Button("开始") { model.start() }
                            .disabled(!model.canStart)
                    }
                    if let message = model.blockingMessage {
                        Text(message).foregroundStyle(.red)
                    }
                }

                Section("实时收据") {
                    row("阶段", model.phase.rawValue)
                    row("时间", String(format: "%.0f s", model.snapshot.elapsedSeconds))
                    row(
                        "首个可用位姿",
                        model.snapshot.firstUsablePoseLatencyMilliseconds.map {
                            String(format: "%.0f ms", $0)
                        } ?? "等待中"
                    )
                    row("处理帧率", String(format: "%.1f fps", model.snapshot.processedFPS))
                    row("P95 延迟", String(format: "%.1f ms", model.snapshot.pipelineP95Milliseconds))
                    row("相机 / App 丢帧", "\(model.snapshot.cameraDrops) / \(model.snapshot.appDrops)")
                    row("位姿", "\(model.snapshot.poseCount)")
                    row("CPU 核等效", String(format: "%.2f", model.snapshot.cpuCoreEquivalent))
                    row("物理内存", String(format: "%.0f MB", model.snapshot.footprintMB))
                    row("热状态", model.snapshot.thermalState)
                }

                if let receipt = model.lastReceiptURL {
                    Section("结果") {
                        ShareLink(item: receipt) { Label("导出实验目录", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .navigationTitle("VIO Replacement Bench")
            .onAppear { model.refreshRecordings() }
            .onChange(of: model.phase) { _, _ in model.refreshRecordings() }
        }
        .fileImporter(
            isPresented: $model.isImportingDataset,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            model.acceptDatasetImport(result)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
