//
//  GamesDatabaseImportOption.swift
//  Delta
//
//  Created by Riley Testut on 5/1/17.
//  Copyright © 2017 Riley Testut. All rights reserved.
//

import UIKit

struct GamesDatabaseImportOption: ImportOption
{
    let title = NSLocalizedString("Games Database", comment: "")
    let image: UIImage? = nil
    
    let searchText: String?
    
    private let presentingViewController: UIViewController
    
    init(searchText: String?, presentingViewController: UIViewController)
    {
        self.searchText = searchText
        self.presentingViewController = presentingViewController
    }
    
    func `import`(withCompletionHandler completionHandler: @escaping (Set<URL>?) -> Void)
    {
        let storyboard = UIStoryboard(name: "GamesDatabase", bundle: nil)
        let navigationController = (storyboard.instantiateInitialViewController() as! UINavigationController)
        
        let gamesDatabaseBrowserViewController = navigationController.topViewController as! GamesDatabaseBrowserViewController
        gamesDatabaseBrowserViewController.searchText = self.searchText
        gamesDatabaseBrowserViewController.selectionHandler = { (metadata) in
            if let artworkURL = metadata.artworkURL
            {
                completionHandler([artworkURL])
            }
            else
            {
                completionHandler(nil)
            }
        }
        
        self.presentingViewController.present(navigationController, animated: true, completion: nil)
    }
}
