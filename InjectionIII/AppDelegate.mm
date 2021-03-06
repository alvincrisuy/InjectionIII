//
//  AppDelegate.m
//  InjectionIII
//
//  Created by John Holdsworth on 06/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//

#import "AppDelegate.h"
#import "SignerService.h"
#import "InjectionServer.h"

AppDelegate *appDelegate;

@interface AppDelegate ()

@property (weak) IBOutlet NSWindow *window;
@end

@implementation AppDelegate {
    IBOutlet NSMenu *statusMenu;
    IBOutlet NSStatusItem *statusItem;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Insert code here to initialize your application
    appDelegate = self;
//    [SignerService startServer:@":8899"];
    [InjectionServer startServer:INJECTION_ADDRESS];

    NSStatusBar *statusBar = [NSStatusBar systemStatusBar];
    statusItem = [statusBar statusItemWithLength:statusBar.thickness];
    statusItem.toolTip = @"Code Injection";
    statusItem.highlightMode = TRUE;
    statusItem.menu = statusMenu;
    statusItem.enabled = TRUE;
    statusItem.title = @"";

    [self setMenuIcon:@"InjectionIdle"];
}

- (void)setMenuIcon:(NSString *)tiffName {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (NSString *path = [NSBundle.mainBundle pathForResource:tiffName ofType:@"tif"]) {
            NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
    //        image.template = TRUE;
            statusItem.image = image;
            statusItem.alternateImage = statusItem.image;
        }
    });
}

- (IBAction)toggleState:(NSMenuItem *)sender {
    sender.state = !sender.state;
}

- (IBAction)donate:sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://johnholdsworth.com/cgi-bin/injection3.cgi"]];
}


- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Insert code here to tear down your application
}


@end
