//
//  GiracleSwiftApp.swift
//  GiracleSwift
//
//  Created by kirota on 2026/11/13.
//

import SwiftUI

@main
struct GiracleSwiftApp: App {
    @State private var auth = AuthStore()
    @State private var realtime = RealtimeClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
                .environment(realtime)
                .task { await auth.restore() }
        }
    }
}
