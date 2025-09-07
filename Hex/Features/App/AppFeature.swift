//
//  AppFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/26/25.
//

import ComposableArchitecture
import Dependencies
import SwiftUI

@Reducer
struct AppFeature {
    enum ActiveTab: Equatable {
        case settings
        case history
        case about
    }

    @ObservableState
    struct State {
        var transcription: TranscriptionFeature.State = .init()
        var settings: SettingsFeature.State = .init()
        var history: HistoryFeature.State = .init()
        var activeTab: ActiveTab = .settings
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case transcription(TranscriptionFeature.Action)
        case settings(SettingsFeature.Action)
        case history(HistoryFeature.Action)
        case setActiveTab(ActiveTab)
        case task
    }

    var body: some ReducerOf<Self> {
        BindingReducer()

        Scope(state: \.transcription, action: \.transcription) {
            TranscriptionFeature()
        }

        Scope(state: \.settings, action: \.settings) {
            SettingsFeature()
        }

        Scope(state: \.history, action: \.history) {
            HistoryFeature()
        }

        Reduce { state, action in
            switch action {
            case .task:
                return .run { _ in
                    @Dependency(\.soundEffects) var soundEffects
                    await soundEffects.preloadSounds()
                }
            case .binding:
                return .none
            case .transcription:
                return .none
            case .settings(.modelDownload(.selectModel)):
                // Cancel any ongoing prewarm when the selected model changes and start prewarming the new selection
                return .merge(
                    .send(.transcription(.cancelPrewarm)),
                    .send(.transcription(.prewarmSelectedModel))
                )
            case .settings:
                return .none
            case .history(.navigateToSettings):
                state.activeTab = .settings
                return .none
            case .history:
                return .none
            case let .setActiveTab(tab):
                state.activeTab = tab
                return .none
            }
        }
    }
}

struct AppView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $store.activeTab) {
                Button {
                    store.send(.setActiveTab(.settings))
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }.buttonStyle(.plain)
                .tag(AppFeature.ActiveTab.settings)

                Button {
                    store.send(.setActiveTab(.history))
                } label: {
                    Label("History", systemImage: "clock")
                }.buttonStyle(.plain)
                .tag(AppFeature.ActiveTab.history)

                Button {
                    store.send(.setActiveTab(.about))
                } label: {
                    Label("About", systemImage: "info.circle")
                }.buttonStyle(.plain)
                .tag(AppFeature.ActiveTab.about)
            }
        } detail: {
            switch store.state.activeTab {
            case .settings:
                SettingsView(store: store.scope(state: \.settings, action: \.settings))
                    .navigationTitle("Settings")
            case .history:
                HistoryView(store: store.scope(state: \.history, action: \.history))
                    .navigationTitle("History")
            case .about:
                AboutView(store: store.scope(state: \.settings, action: \.settings))
                    .navigationTitle("About")
            }
        }
        .task {
            await store.send(.task).finish()
        }
        .enableInjection()
    }
}
