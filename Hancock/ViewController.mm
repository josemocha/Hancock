//
//  ViewController.m
//  CertAndSign
//
//  Created by Jeremy Agostino on 6/27/16.
//  Copyright © 2016 GroundControl. All rights reserved.
//

#import "ViewController.h"
#import <Security/Security.h>
#import <Security/SecCode.h>
#import "SecCodeSigner.h"

@implementation ViewController

/*
 * Sets up some UI elements and initializes other members
 */

- (void)viewDidLoad
{
	[super viewDidLoad];
	
	[self.spinner setHidden:YES];
	
	[self.popup removeAllItems];
	
	self.title = @"Hancock - Signing Tool";
	self.signButton.title = @"Sign...";
	self.unsignButton.title = @"Unsign...";
	
	[self validateButtons];
	
	self.loadedIdentities = [NSMutableArray new];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		[self loadIdentities];
	});
}

- (void)setRepresentedObject:(id)representedObject
{
	[super setRepresentedObject:representedObject];
	
	[self validateButtons];
}

/*
 * The Sign... button is only enabled if there is an identity in the list to be selected
 */

- (void)validateButtons
{
	self.popup.enabled = self.popup.numberOfItems > 0;
	self.signButton.enabled = self.popup.enabled;
}

/*
 * Helper that makes an NSOpenPanel useful for choosing single files
 */

static NSOpenPanel * _CreateOpenPanel()
{
	auto openPanel = [NSOpenPanel new];
	openPanel.canChooseFiles = YES;
	openPanel.canChooseDirectories = NO;
	openPanel.canCreateDirectories = NO;
	openPanel.allowsMultipleSelection = NO;
	return openPanel;
}

/*
 * Sign... button action handler that prompts for a file and invokes the signFile:withIdentity: method
 */

- (IBAction)actionSignFile:(id)sender
{
	auto openPanel = _CreateOpenPanel();
	openPanel.title = @"Choose a file to sign";
	
	[openPanel beginSheetModalForWindow:NSApp.mainWindow completionHandler:^(NSModalResponse result) {
		
		if (result == NSFileHandlingPanelOKButton) {
			// Make local ref so we can use them on a global queue without race condition
			auto signFileURL = openPanel.URL;
			
			if (signFileURL != nil) {
				
				SecIdentityRef chosenIdentity = [self copySelectedIdentity];
				
				if (chosenIdentity != nullptr) {
					
					dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
						
						[self startSpinning];
						
						[self signCodeFile:signFileURL withIdentity:chosenIdentity];
						
						[self stopSpinning];
						
						CFRelease(chosenIdentity);
					});
				}
			}
		}
	}];
}

/*
 * Unsign... button action handler that prompts for a file and invokes the unsignFile: method
 */

- (IBAction)actionUnsignFile:(id)sender
{
	auto openPanel = _CreateOpenPanel();
	openPanel.title = @"Choose a file to unsign";
	
	[openPanel beginSheetModalForWindow:NSApp.mainWindow completionHandler:^(NSModalResponse result) {
		
		if (result == NSFileHandlingPanelOKButton) {
			// Make local ref so we can use them on a global queue without race condition
			auto fileURL = openPanel.URL;
			
			if (fileURL != nil) {
				
				dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
					
					[self startSpinning];
					
					[self unsignFile:fileURL];
					
					[self stopSpinning];
				});
			}
		}
	}];
}

/*
 * Gets the identity object for the item currently selected in the list
 */

- (SecIdentityRef)copySelectedIdentity
{
	auto chosenIndex = self.popup.indexOfSelectedItem;
	
	if (chosenIndex >= self.loadedIdentities.count) {
		return nullptr;
	}
	
	return (SecIdentityRef)CFBridgingRetain(self.loadedIdentities[chosenIndex]);
}

/*
 * External method that can be used to invoke the sign action on a filename we got elsewhere
 */

- (void)handleDraggedFilename:(NSString *)filename
{
	auto chosenIdentity = [self copySelectedIdentity];
	
	if (chosenIdentity != nullptr) {
		
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			
			[self startSpinning];
			
			[self signFile:[NSURL fileURLWithPath:filename] withIdentity:chosenIdentity];
			
			[self stopSpinning];
			
			CFRelease(chosenIdentity);
		});
	}
}

static NSString * const kStrCheckmark = @"✅";
//Checkmark
//Unicode: U+2714 U+FE0F, UTF-8: E2 9C 94 EF B8 8F

static NSString * const kStrCross = @"❌";
//cross mark
//Unicode: U+274C, UTF-8: E2 9D 8C

static NSString * const kStrCaution = @"⚠️";
//warning sign
//Unicode: U+26A0 U+FE0F, UTF-8: E2 9A A0 EF B8 8F

static NSString * const kStrQuestion = @"❓";
//black question mark ornament
//Unicode: U+2753, UTF-8: E2 9D 93

/*
 * Loads the popup list by asking Keychain for all identities and getting their certs' name and serial number for display
 * Also populates an array member with the valid identities so we can sign with a chosen one later
 */

- (void)loadIdentities
{
	// Ask for basically all identities in the keychain
	auto query = @{
				   (__bridge NSString *)kSecClass:(__bridge NSString *)kSecClassIdentity,
				   (__bridge NSString *)kSecReturnRef: @(YES),
				   (__bridge NSString *)kSecMatchLimit: (__bridge NSString *)kSecMatchLimitAll,
				   };
	
	OSStatus oserr;
	CFArrayRef identsCF = NULL;
	oserr = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&identsCF);
	
	if (oserr != 0) {
		NSString * err = CFBridgingRelease(SecCopyErrorMessageString(oserr, nullptr));
		[self showAlertWithMessage:@"Failed to Load Identities" informativeText:[NSString stringWithFormat:@"An internal error occurred while loading identities to list for signing. Security says: %@.", err]];
		return;
	}
	
	// Clear the array and popup menu
	dispatch_async(dispatch_get_main_queue(), ^{
		[self.loadedIdentities removeAllObjects];
		[self.popup removeAllItems];
	});
	
	SecPolicyRef policy = SecPolicyCreateBasicX509();
	
	NSArray * idents = CFBridgingRelease(identsCF);
	for (id ident in idents) {
		
		// The certificate has the useful metadata for display
		SecCertificateRef cert = nullptr;
		SecIdentityCopyCertificate((__bridge SecIdentityRef)ident, &cert);
		
		if (cert == nullptr) {
			continue;
		}
		
		CFStringRef nameCF = nullptr;
		SecCertificateCopyCommonName(cert, &nameCF);
		
		CFDataRef serialCF = SecCertificateCopySerialNumber(cert, nullptr);
		
		SecTrustRef trust = nullptr;
		SecTrustCreateWithCertificates(cert, policy, &trust);
		
		SecTrustResultType result;
		SecTrustEvaluate(trust, &result);
		
		CFRelease(trust);
		
		NSString * trustIndicator;
		switch (result) {
			case kSecTrustResultProceed:
			case kSecTrustResultUnspecified:
				trustIndicator = kStrCheckmark;
				break;
				
			case kSecTrustResultConfirm:
				trustIndicator = kStrQuestion;
				break;
				
			case kSecTrustResultRecoverableTrustFailure:
				trustIndicator = kStrCaution;
				break;
				
			case kSecTrustResultFatalTrustFailure:
			case kSecTrustResultOtherError:
			case kSecTrustResultInvalid:
			case kSecTrustResultDeny:
			default:
				trustIndicator = kStrCross;
				break;
		}
		
		CFRelease(cert);
		
		NSString * name = CFBridgingRelease(nameCF);
		NSData * serial = CFBridgingRelease(serialCF);
		
		if (name.length > 0 && serial.length > 0) {
			
			// Sometimes the serial number is less than 64 bits, in which case I zero-pad it
			if (serial.length < sizeof(SInt64)) {
				auto temp = [NSMutableData new];
				[temp increaseLengthBy:sizeof(SInt64) - serial.length];
				[temp appendData:serial];
				serial = temp;
			}
			
			// Keychain displays the serial number as a big-endian 64-bit signed integer
			// So swap it and make a number
			SInt64 serialBig = CFSwapInt64HostToBig(*((SInt64*)serial.bytes));
			NSNumber * serialNumber = CFBridgingRelease(CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &serialBig));
			
			// Popup menu item title is the name of the cert followed by serial number
			NSString * title = [NSString stringWithFormat:@"%@ %@ [%@]", trustIndicator, name, serialNumber];
			
			// Add this identity to the array and popup menu
			dispatch_async(dispatch_get_main_queue(), ^{
				
				// Popups can only contains unique titles so make sure there are no dupes
				if (![self.popup.itemTitles containsObject:title]) {
					[self.loadedIdentities addObject:ident];
					[self.popup addItemWithTitle:title];
				}
			});
		}
	}
	
	CFRelease(policy);
	
	dispatch_async(dispatch_get_main_queue(), ^{
		[self validateButtons];
	});
}

- (void)signFile:(NSURL*)fileURL withIdentity:(SecIdentityRef)chosenIdentity
{
	NSString * extension = fileURL.pathExtension;
	
	if ([extension compare:@"pkg" options:NSCaseInsensitiveSearch] == NSOrderedSame ||
		[extension compare:@"dmg" options:NSCaseInsensitiveSearch] == NSOrderedSame) {
		[self signCodeFile:fileURL withIdentity:chosenIdentity];
	}
	else {
		[self signOtherFile:fileURL withIdentity:chosenIdentity];
	}
}

- (void)signCodeFile:(NSURL*)fileURL withIdentity:(SecIdentityRef)chosenIdentity
{
	auto parameters = @{
						(__bridge id)kSecCodeSignerIdentity: (__bridge id)chosenIdentity,
						(__bridge id)kSecCodeSignerRequireTimestamp: @YES,
						};
	OSStatus oserr;
	
	NSFileManager * fm = [NSFileManager defaultManager];
	NSURL * tempFileURL = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[NSUUID UUID].UUIDString];
	
	// Copy the package to a temporary URL
	NSError * fmErr = nil;
	BOOL fmOk = [fm copyItemAtURL:fileURL toURL:tempFileURL error:&fmErr];;
	
	if (!fmOk) {
		[self showAlertWithMessage:@"Failed to Load Package" informativeText:[NSString stringWithFormat:@"Could not copy the selected package '%@' to a temporary location. File manager says: %@", fileURL.lastPathComponent, fmErr.localizedDescription]];
		return;
	}
	
	SecCodeSignerRef codeSigner = nullptr;
	oserr = SecCodeSignerCreate((__bridge CFDictionaryRef)parameters, kSecCSRemoveSignature, &codeSigner);
	
	if (oserr != 0) {
		NSString * err = CFBridgingRelease(SecCopyErrorMessageString(oserr, nullptr));
		[self showAlertWithMessage:@"Failed to Initialize Signing" informativeText:[NSString stringWithFormat:@"An internal error occurred while attempting to sign '%@'. Security says: %@.", fileURL.lastPathComponent, err]];
		return;
	}
	
	SecStaticCodeRef staticCode = nullptr;
	oserr = SecStaticCodeCreateWithPath((__bridge CFURLRef)tempFileURL, kSecCSDefaultFlags, &staticCode);
	
	if (oserr != 0) {
		NSString * err = CFBridgingRelease(SecCopyErrorMessageString(oserr, nullptr));
		[self showAlertWithMessage:@"Failed to Open Package" informativeText:[NSString stringWithFormat:@"An internal error occurred while attempting to sign '%@'. Security says: %@.", fileURL.lastPathComponent, err]];
		return;
	}
	
	CFErrorRef signErrCF = nullptr;
	oserr = SecCodeSignerAddSignatureWithErrors(codeSigner, staticCode, kSecCSDefaultFlags, &signErrCF);
	
	if (oserr != 0) {
		NSString * err = CFBridgingRelease(SecCopyErrorMessageString(oserr, nullptr));
		NSError * signErr = CFBridgingRelease(signErrCF);
		[self showAlertWithMessage:@"Failed to Add Signatures" informativeText:[NSString stringWithFormat:@"An internal error occurred while attempting to sign '%@'. Errors: %@. Security says: %@.", fileURL.lastPathComponent, signErr.localizedDescription, err]];
		return;
	}
	
	auto newFilename = [self filenameForURL:fileURL withAppendedString:@"Signed"];
	
	// Display a save box with a new default filename
	dispatch_async(dispatch_get_main_queue(), ^{
		
		auto savePanel = [NSSavePanel new];
		savePanel.canCreateDirectories = YES;
		savePanel.nameFieldStringValue = newFilename;
		savePanel.title = @"Choose where to save signed package";
		
		[savePanel beginSheetModalForWindow:NSApp.mainWindow completionHandler:^(NSModalResponse result) {
			
			if (result == NSFileHandlingPanelOKButton) {
				auto saveURL = savePanel.URL;
				
				NSError * fmErr = nil;
				auto fmOk = [fm moveItemAtURL:tempFileURL toURL:saveURL error:&fmErr];
				
				if (!fmOk) {
					[self showAlertWithMessage:@"Failed to Load Package" informativeText:[NSString stringWithFormat:@"Could not copy the signed package to the target location. File manager says: %@", fmErr.localizedDescription]];
					return;
				}
			}
			
			[fm removeItemAtURL:tempFileURL error:nil];
		}];
	});
}

/*
 * This method signs a file with the given identity and prompts the user where to save it
 */

- (void)signOtherFile:(NSURL*)fileURL withIdentity:(SecIdentityRef)chosenIdentity
{
	auto data = [NSData dataWithContentsOfURL:fileURL];
	if (data.length == 0) {
		[self showAlertWithMessage:@"No File Selected" informativeText:@"Please select a file to sign with the chosen identity."];
		return;
	}
	
	OSStatus oserr;
	
	// This method simply signs data when given an identity
	// It may generate a user prompt for permission to sign
	CFDataRef outDataCF = NULL;
	oserr = CMSEncodeContent(chosenIdentity, NULL, NULL, false, kCMSAttrNone,
							 data.bytes, data.length, &outDataCF);
	
	if (oserr != 0) {
		NSString * err = oserr == -1 ? @"Permission to sign with identitiy was denied" : CFBridgingRelease(SecCopyErrorMessageString(oserr, nullptr));
		[self showAlertWithMessage:@"Signing Failed" informativeText:[NSString stringWithFormat:@"An internal error occurred while attempting to sign '%@'. Security says: %@.", fileURL.lastPathComponent, err]];
		return;
	}
	
	NSData * outData = CFBridgingRelease(outDataCF);
	auto newFilename = [self filenameForURL:fileURL withAppendedString:@"Signed"];
	
	// Display a save box with a new default filename
	dispatch_async(dispatch_get_main_queue(), ^{
		
		auto savePanel = [NSSavePanel new];
		savePanel.canCreateDirectories = YES;
		savePanel.nameFieldStringValue = newFilename;
		savePanel.title = @"Choose where to save signed data";
		
		[savePanel beginSheetModalForWindow:NSApp.mainWindow completionHandler:^(NSModalResponse result) {
			if (result == NSFileHandlingPanelOKButton) {
				auto saveURL = savePanel.URL;
				[outData writeToURL:saveURL atomically:YES];
			}
		}];
	});
}

/*
 * This method unsigns a file and prompts the user where to save it
 */

- (void)unsignFile:(NSURL*)fileURL
{
	auto data = [NSData dataWithContentsOfURL:fileURL];
	if (data.length == 0) {
		[self showAlertWithMessage:@"No File Selected" informativeText:@"Please select a CMS encoded file to unsign."];
		return;
	}
	
	CMSDecoderRef decoder = NULL;
	CFDataRef outDataCF = NULL;
	
	// Create a decoder, add the data, finalize and retrieve the resulting data
	// If the data isn't signed, an error code will be returned along the way
	OSStatus oserr = CMSDecoderCreate(&decoder);
	if (oserr == noErr) {
		oserr = CMSDecoderUpdateMessage(decoder, data.bytes, data.length);
	}
	if (oserr == noErr) {
		oserr = CMSDecoderFinalizeMessage(decoder);
	}
	if (oserr == noErr) {
		oserr = CMSDecoderCopyContent(decoder, &outDataCF);
	}
	
	NSData * outData = CFBridgingRelease(outDataCF);
	
	if (oserr == noErr && outData.length > 0) {
		// Decoding succeeded
		auto newFilename = [self filenameForURL:fileURL withAppendedString:@"Unsigned"];
		
		// Display a save box with a new default filename
		dispatch_async(dispatch_get_main_queue(), ^{
			
			auto savePanel = [NSSavePanel new];
			savePanel.canCreateDirectories = YES;
			savePanel.nameFieldStringValue = newFilename;
			savePanel.title = @"Choose where to save unsigned data";
			
			[savePanel beginSheetModalForWindow:NSApp.mainWindow completionHandler:^(NSModalResponse result) {
				if (result == NSFileHandlingPanelOKButton) {
					auto saveURL = savePanel.URL;
					[outData writeToURL:saveURL atomically:YES];
				}
			}];
		});
	}
	else {
		[self showAlertWithMessage:@"Failed to Unsign" informativeText:[NSString stringWithFormat:@"The selected file '%@' is probably not a CMS encoded (signed) file.", fileURL.lastPathComponent]];
	}
}

/*
 * Generates a new filename based on a URL with a string appended to it after a hyphen
 */

- (NSString *)filenameForURL:(NSURL*)fileURL withAppendedString:(NSString*)append
{
	auto originalFilename = fileURL.lastPathComponent;
	auto basename = [originalFilename stringByDeletingPathExtension];
	
	return [NSString stringWithFormat:@"%@-%@.%@", basename, append, originalFilename.pathExtension];
}

/*
 * Increment the count of active jobs and start the spinner if needed
 */

- (void)startSpinning
{
	dispatch_async(dispatch_get_main_queue(), ^{
		
		if (self.spinCount == 0) {
			[self.spinner setHidden:NO];
			[self.spinner startAnimation:self];
		}
		
		self.spinCount++;
	});
}

/*
 * Decrement the count of active jobs and stop the spinner if needed
 */

- (void)stopSpinning
{
	dispatch_async(dispatch_get_main_queue(), ^{
		
		self.spinCount--;
		
		if (self.spinCount == 0) {
			[self.spinner setHidden:YES];
			[self.spinner stopAnimation:self];
		}
	});
}

/*
 * Convenience method for showing an alert box
 */

- (void)showAlertWithMessage:(NSString*)message informativeText:(NSString*)informativeText
{
	dispatch_async(dispatch_get_main_queue(), ^{
		auto alert = [NSAlert new];
		alert.messageText = message;
		alert.informativeText = informativeText;
		[alert beginSheetModalForWindow:NSApp.mainWindow completionHandler:^(NSModalResponse result) {}];
	});
}

@end
