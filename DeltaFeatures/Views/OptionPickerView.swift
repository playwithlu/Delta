//
//  OptionPickerView.swift
//  Delta
//
//  Created by Riley Testut on 4/10/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

import SwiftUI

// Type must be public, but not its properties.
public struct OptionPickerView<Value: LocalizedOptionValue>: View
{
    var name: LocalizedStringKey
    var options: [Value]
    
    @Binding var selectedValue: Value

    public init(name: LocalizedStringKey, options: [Value], selectedValue: Binding<Value>) {
        self.name = name
        self.options = options
        self._selectedValue = selectedValue
    }

    public var body: some View {
        Picker(name, selection: $selectedValue) {
            ForEach(options, id: \.self) { value in
                // Tag each option so the Picker selection matches correctly, including nil
                value.localizedDescription.tag(value)
            }
        }
        .pickerStyle(.menu)
        .displayInline()
    }
}
