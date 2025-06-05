//
//  ContentView.swift
//  QCRunner
//
//  Created by Blake on 02/06/2025.
//

import SwiftUI

struct ContentView: View {
    var progress = 0.0
    var total = 1
    var textToDisplay = "Currently processing: "
    
    var body: some View {
        VStack {
            ProgressView(value: progress)
                .scaleEffect(0.75)
            Text(textToDisplay)
        }
    }

    mutating func updatePath(to newPath: String){
        textToDisplay = "Currently processing: " + newPath
    }
    
    mutating func updateCurrentPlace(to newPlace: Int){
        progress = Double(newPlace / total)
    }
    
    mutating func updateTotal(to newTotal: Int){
        total = newTotal
    }

}

#Preview {
    ContentView()
}
