//
//  EmulatorCore+Delta.swift
//  Delta
//
//  Created by Riley Testut on 8/11/16.
//  Copyright © 2016 Riley Testut. All rights reserved.
//

import DeltaCore
import ObjectiveC

private var _isWirelessMultiplayerActive: UInt8 = 0

extension EmulatorCore
{
    var isWirelessMultiplayerActive: Bool {
        get { objc_getAssociatedObject(self, &_isWirelessMultiplayerActive) as? Bool ?? false }
        set { objc_setAssociatedObject(self, &_isWirelessMultiplayerActive, newValue as NSNumber, objc_AssociationPolicy.OBJC_ASSOCIATION_COPY) }
    }
}

extension EmulatorCore
{
    func activateCheatWithErrorLogging(_ cheat: Cheat)
    {
        do
        {
            try self.activate(cheat)
        }
        catch EmulatorCore.CheatError.invalid
        {
            print("Invalid cheat:", cheat.name, cheat.code)
        }
        catch
        {
            print("Unknown Cheat Error:", error, cheat.name, cheat.code)
        }
    }
    
    func updateCheats()
    {
        guard let game = self.game as? Game else { return }
        
        let running = (self.state == .running)
        
        if running
        {
            // Core MUST be paused when activating cheats, or else race conditions could crash the core
            self.pause()
        }
        
        let backgroundContext = DatabaseManager.shared.newBackgroundContext()
        backgroundContext.performAndWait {
            
            let predicate = NSPredicate(format: "%K == %@", #keyPath(Cheat.game), game)
            
            let cheats = Cheat.instancesWithPredicate(predicate, inManagedObjectContext: backgroundContext, type: Cheat.self)
            for cheat in cheats
            {
                if cheat.isEnabled
                {
                    self.activateCheatWithErrorLogging(cheat)
                }
                else
                {
                    self.deactivate(cheat)
                }
            }
        }
        
        if running
        {
            self.resume()
        }

    }
}
