//
//  ContentView.swift
//  GiracleSwift
//
//  Created by kirota on 2026/11/13.
//

import SwiftUI

/// ログイン状態に応じて画面を切り替えるルート
struct ContentView: View {
    @Environment(AuthStore.self) private var auth

    var body: some View {
        switch auth.state {
        case .checking:
            ProgressView()
        case .signedOut:
            SignInView()
        case .signedIn:
            MainTabView()
        }
    }
}

#Preview {
    ContentView()
        .environment(AuthStore())
}
