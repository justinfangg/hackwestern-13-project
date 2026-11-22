//
//  SupabaseConfig.swift
//  FogOfWar
//
//  Supabase project the app talks to. The publishable key is meant to be public (row-level security
//  blocks direct table access; the app only calls Edge Functions). NEVER put the secret key here.
//

import Foundation
import FogKit

enum SupabaseConfig {
    static let backend = BackendConfig(
        projectURL: URL(string: "https://qsxakuynoyxsyxhkxvuo.supabase.co")!,
        anonKey: "sb_publishable_EUUcwKCKsR2RDm091M_Zuw_0A3l1r7E"
    )
}
