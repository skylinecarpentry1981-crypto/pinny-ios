import SwiftUI

struct LoadingView: View {
    var body: some View {
        ZStack {
            Color.fm.background.ignoresSafeArea()
            ProgressView()
                .progressViewStyle(.circular)
        }
    }
}
