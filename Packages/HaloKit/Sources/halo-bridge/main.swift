import Foundation
import HaloBridgeKit

exit(BridgeCLI.run(arguments: Array(CommandLine.arguments.dropFirst()), keyStore: KeychainKeyStore.bridge))
