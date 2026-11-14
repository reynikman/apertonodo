import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru'),
  ];

  /// No description provided for @updateTitle.
  ///
  /// In en, this message translates to:
  /// **'Update available'**
  String get updateTitle;

  /// No description provided for @updateVersion.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String updateVersion(String version);

  /// No description provided for @updateInstall.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get updateInstall;

  /// No description provided for @updateSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip this version'**
  String get updateSkip;

  /// No description provided for @updateDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading… {percent}%'**
  String updateDownloading(int percent);

  /// No description provided for @updateFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update. Try again.'**
  String get updateFailed;

  /// No description provided for @updateCheck.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get updateCheck;

  /// No description provided for @updateLatest.
  ///
  /// In en, this message translates to:
  /// **'You have the latest version'**
  String get updateLatest;

  /// No description provided for @loginTitle.
  ///
  /// In en, this message translates to:
  /// **'Connect to Apertono'**
  String get loginTitle;

  /// No description provided for @ratingStar.
  ///
  /// In en, this message translates to:
  /// **'{n} of 5'**
  String ratingStar(int n);

  /// No description provided for @ratingDislike.
  ///
  /// In en, this message translates to:
  /// **'Dislike'**
  String get ratingDislike;

  /// No description provided for @ratingFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save the rating'**
  String get ratingFailed;

  /// No description provided for @playerRate.
  ///
  /// In en, this message translates to:
  /// **'Rate'**
  String get playerRate;

  /// No description provided for @playerLyrics.
  ///
  /// In en, this message translates to:
  /// **'Lyrics'**
  String get playerLyrics;

  /// No description provided for @playerHeartHint.
  ///
  /// In en, this message translates to:
  /// **'Hold the heart to rate the song or mark it as disliked'**
  String get playerHeartHint;

  /// No description provided for @libraryRated.
  ///
  /// In en, this message translates to:
  /// **'Rated'**
  String get libraryRated;

  /// No description provided for @ratedFrom.
  ///
  /// In en, this message translates to:
  /// **'{n} and up'**
  String ratedFrom(int n);

  /// No description provided for @ratedEmpty.
  ///
  /// In en, this message translates to:
  /// **'No rated songs yet'**
  String get ratedEmpty;

  /// No description provided for @dislikedEmpty.
  ///
  /// In en, this message translates to:
  /// **'No disliked songs'**
  String get dislikedEmpty;

  /// No description provided for @ratedFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load the list'**
  String get ratedFailed;

  /// No description provided for @ratedRetry.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get ratedRetry;

  /// No description provided for @loginSessionExpired.
  ///
  /// In en, this message translates to:
  /// **'Session expired. Sign in again.'**
  String get loginSessionExpired;

  /// No description provided for @loginServerAddress.
  ///
  /// In en, this message translates to:
  /// **'Server address'**
  String get loginServerAddress;

  /// No description provided for @loginAddressInvalid.
  ///
  /// In en, this message translates to:
  /// **'Use HTTPS or a home-network HTTP address.'**
  String get loginAddressInvalid;

  /// No description provided for @loginAddressUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This server is not supported'**
  String get loginAddressUnsupported;

  /// No description provided for @loginAddressUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Cannot reach the server at this address'**
  String get loginAddressUnreachable;

  /// No description provided for @loginAddressExample.
  ///
  /// In en, this message translates to:
  /// **'e.g. 192.168.1.20:8088'**
  String get loginAddressExample;

  /// No description provided for @loginConnectVia.
  ///
  /// In en, this message translates to:
  /// **'Will connect to {address}'**
  String loginConnectVia(String address);

  /// No description provided for @loginChangeServer.
  ///
  /// In en, this message translates to:
  /// **'Another server'**
  String get loginChangeServer;

  /// No description provided for @loginNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get loginNext;

  /// No description provided for @historyPauseTitle.
  ///
  /// In en, this message translates to:
  /// **'Don’t record history'**
  String get historyPauseTitle;

  /// No description provided for @historyPauseHint.
  ///
  /// In en, this message translates to:
  /// **'For an hour, till tomorrow or indefinitely'**
  String get historyPauseHint;

  /// No description provided for @historyPauseForHour.
  ///
  /// In en, this message translates to:
  /// **'For an hour'**
  String get historyPauseForHour;

  /// No description provided for @historyPauseTillTomorrow.
  ///
  /// In en, this message translates to:
  /// **'Till tomorrow'**
  String get historyPauseTillTomorrow;

  /// No description provided for @historyPauseForever.
  ///
  /// In en, this message translates to:
  /// **'Until I turn it back on'**
  String get historyPauseForever;

  /// No description provided for @historyPauseForeverOn.
  ///
  /// In en, this message translates to:
  /// **'Until you turn it back on'**
  String get historyPauseForeverOn;

  /// No description provided for @historyPauseUntil.
  ///
  /// In en, this message translates to:
  /// **'Until {time}'**
  String historyPauseUntil(String time);

  /// No description provided for @historyClear.
  ///
  /// In en, this message translates to:
  /// **'Clear history'**
  String get historyClear;

  /// No description provided for @historyClearQuestion.
  ///
  /// In en, this message translates to:
  /// **'Erase all listening history? This can’t be undone'**
  String get historyClearQuestion;

  /// No description provided for @historyClearConfirm.
  ///
  /// In en, this message translates to:
  /// **'Erase'**
  String get historyClearConfirm;

  /// No description provided for @historyClearCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get historyClearCancel;

  /// No description provided for @historyError.
  ///
  /// In en, this message translates to:
  /// **'That didn’t work. Check your connection and try again'**
  String get historyError;

  /// No description provided for @historyRemoved.
  ///
  /// In en, this message translates to:
  /// **'Removed from history'**
  String get historyRemoved;

  /// No description provided for @historyRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove from history'**
  String get historyRemove;

  /// No description provided for @historyUndo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get historyUndo;

  /// No description provided for @historyRemoveFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t remove from history'**
  String get historyRemoveFailed;

  /// No description provided for @loginUsername.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get loginUsername;

  /// No description provided for @loginPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get loginPassword;

  /// No description provided for @prefetchTitle.
  ///
  /// In en, this message translates to:
  /// **'Preload the next song'**
  String get prefetchTitle;

  /// No description provided for @prefetchAlways.
  ///
  /// In en, this message translates to:
  /// **'Always'**
  String get prefetchAlways;

  /// No description provided for @prefetchWifiOnly.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi only'**
  String get prefetchWifiOnly;

  /// No description provided for @prefetchNever.
  ///
  /// In en, this message translates to:
  /// **'Never'**
  String get prefetchNever;

  /// No description provided for @prefetchNeverHint.
  ///
  /// In en, this message translates to:
  /// **'A short pause between songs; saves mobile data'**
  String get prefetchNeverHint;

  /// No description provided for @qualityTitle.
  ///
  /// In en, this message translates to:
  /// **'Sound quality'**
  String get qualityTitle;

  /// No description provided for @qualityAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get qualityAuto;

  /// No description provided for @qualityAutoHint.
  ///
  /// In en, this message translates to:
  /// **'Original on Wi-Fi, data saver on mobile data'**
  String get qualityAutoHint;

  /// No description provided for @qualityEconomy.
  ///
  /// In en, this message translates to:
  /// **'Always data saver'**
  String get qualityEconomy;

  /// No description provided for @qualityEconomyHint.
  ///
  /// In en, this message translates to:
  /// **'Less data on any network'**
  String get qualityEconomyHint;

  /// No description provided for @qualityLossless.
  ///
  /// In en, this message translates to:
  /// **'Lossless only'**
  String get qualityLossless;

  /// No description provided for @qualityLosslessHint.
  ///
  /// In en, this message translates to:
  /// **'FLAC when available. Otherwise plays what there is'**
  String get qualityLosslessHint;

  /// No description provided for @loudnessTitle.
  ///
  /// In en, this message translates to:
  /// **'Even loudness'**
  String get loudnessTitle;

  /// No description provided for @loudnessHint.
  ///
  /// In en, this message translates to:
  /// **'Quieter loud tracks'**
  String get loudnessHint;

  /// No description provided for @formatBadgeSpoken.
  ///
  /// In en, this message translates to:
  /// **'Format: {format}'**
  String formatBadgeSpoken(String format);

  /// No description provided for @loginSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get loginSignIn;

  /// No description provided for @loginErrorTimeout.
  ///
  /// In en, this message translates to:
  /// **'Server timed out'**
  String get loginErrorTimeout;

  /// No description provided for @scrobbleWhy.
  ///
  /// In en, this message translates to:
  /// **'This is optional. ListenBrainz and Last.fm are free sites that keep your listening statistics: what you played and how much. The history stays yours even if you change players. Connect your profile and the app will send the songs you play there.'**
  String get scrobbleWhy;

  /// No description provided for @scrobbleWhyLbOnly.
  ///
  /// In en, this message translates to:
  /// **'This is optional. ListenBrainz is a free site that keeps your listening statistics: what you played and how much. The history stays yours even if you change players. Connect your profile and the app will send the songs you play there.'**
  String get scrobbleWhyLbOnly;

  /// No description provided for @scrobbleStateOff.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get scrobbleStateOff;

  /// No description provided for @scrobbleStateOn.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get scrobbleStateOn;

  /// No description provided for @scrobbleStateBadToken.
  ///
  /// In en, this message translates to:
  /// **'The service rejected the key. Connect again.'**
  String get scrobbleStateBadToken;

  /// No description provided for @scrobbleStatePending.
  ///
  /// In en, this message translates to:
  /// **'Waiting for your approval'**
  String get scrobbleStatePending;

  /// No description provided for @scrobbleTokenLabel.
  ///
  /// In en, this message translates to:
  /// **'ListenBrainz token'**
  String get scrobbleTokenLabel;

  /// No description provided for @scrobbleLbWhere.
  ///
  /// In en, this message translates to:
  /// **'Where to get the token'**
  String get scrobbleLbWhere;

  /// No description provided for @scrobbleConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get scrobbleConnect;

  /// No description provided for @scrobbleDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get scrobbleDisconnect;

  /// No description provided for @scrobbleLastfmAllow.
  ///
  /// In en, this message translates to:
  /// **'Allow in Last.fm'**
  String get scrobbleLastfmAllow;

  /// No description provided for @scrobbleLastfmCheck.
  ///
  /// In en, this message translates to:
  /// **'Check approval'**
  String get scrobbleLastfmCheck;

  /// No description provided for @scrobbleLastfmCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get scrobbleLastfmCancel;

  /// No description provided for @scrobbleLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load settings'**
  String get scrobbleLoadFailed;

  /// No description provided for @scrobbleRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get scrobbleRetry;

  /// No description provided for @scrobbleErrorTokenShape.
  ///
  /// In en, this message translates to:
  /// **'This does not look like a token: 8 to 200 characters, no spaces'**
  String get scrobbleErrorTokenShape;

  /// No description provided for @scrobbleErrorSave.
  ///
  /// In en, this message translates to:
  /// **'Could not save. Try again.'**
  String get scrobbleErrorSave;

  /// No description provided for @scrobbleErrorLastfmStart.
  ///
  /// In en, this message translates to:
  /// **'Last.fm did not answer. Try later.'**
  String get scrobbleErrorLastfmStart;

  /// No description provided for @scrobbleErrorLastfmNotYet.
  ///
  /// In en, this message translates to:
  /// **'Not approved yet. Approve on the Last.fm page and check again.'**
  String get scrobbleErrorLastfmNotYet;

  /// No description provided for @scrobbleErrorLastfmExpired.
  ///
  /// In en, this message translates to:
  /// **'The approval timed out. Start again.'**
  String get scrobbleErrorLastfmExpired;

  /// No description provided for @scrobbleHint.
  ///
  /// In en, this message translates to:
  /// **'Listens go only to connected services. While “Do not record” is on, nothing is sent.'**
  String get scrobbleHint;

  /// No description provided for @loginErrorUnauthorized.
  ///
  /// In en, this message translates to:
  /// **'Incorrect username or password'**
  String get loginErrorUnauthorized;

  /// No description provided for @loginErrorBadCertificate.
  ///
  /// In en, this message translates to:
  /// **'Invalid server certificate'**
  String get loginErrorBadCertificate;

  /// No description provided for @loginErrorNetwork.
  ///
  /// In en, this message translates to:
  /// **'Cannot connect to server'**
  String get loginErrorNetwork;

  /// No description provided for @searchFailureNoAccess.
  ///
  /// In en, this message translates to:
  /// **'No access: the build key does not match the server'**
  String get searchFailureNoAccess;

  /// No description provided for @searchFailureCatalogDown.
  ///
  /// In en, this message translates to:
  /// **'The catalog is not responding — try again in a minute'**
  String get searchFailureCatalogDown;

  /// No description provided for @searchFailureTooMany.
  ///
  /// In en, this message translates to:
  /// **'Too many requests — wait and try again'**
  String get searchFailureTooMany;

  /// No description provided for @searchFailureNoAnswer.
  ///
  /// In en, this message translates to:
  /// **'The server did not respond — check your connection'**
  String get searchFailureNoAnswer;

  /// No description provided for @searchRecent.
  ///
  /// In en, this message translates to:
  /// **'Recent searches'**
  String get searchRecent;

  /// No description provided for @searchClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get searchClear;

  /// No description provided for @searchHeard.
  ///
  /// In en, this message translates to:
  /// **'Recently played'**
  String get searchHeard;

  /// No description provided for @searchArtistLabel.
  ///
  /// In en, this message translates to:
  /// **'Artist'**
  String get searchArtistLabel;

  /// No description provided for @searchTracks.
  ///
  /// In en, this message translates to:
  /// **'Tracks'**
  String get searchTracks;

  /// No description provided for @searchTitle.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get searchTitle;

  /// No description provided for @searchHint.
  ///
  /// In en, this message translates to:
  /// **'Artist or song'**
  String get searchHint;

  /// No description provided for @searchEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing found'**
  String get searchEmpty;

  /// No description provided for @catalogKindLive.
  ///
  /// In en, this message translates to:
  /// **'live'**
  String get catalogKindLive;

  /// No description provided for @catalogKindCompilation.
  ///
  /// In en, this message translates to:
  /// **'compilation'**
  String get catalogKindCompilation;

  /// No description provided for @catalogKindSingle.
  ///
  /// In en, this message translates to:
  /// **'single'**
  String get catalogKindSingle;

  /// No description provided for @catalogKindAlbum.
  ///
  /// In en, this message translates to:
  /// **'album'**
  String get catalogKindAlbum;

  /// No description provided for @catalogArtistOne.
  ///
  /// In en, this message translates to:
  /// **'artist'**
  String get catalogArtistOne;

  /// No description provided for @catalogArtistFew.
  ///
  /// In en, this message translates to:
  /// **'artists'**
  String get catalogArtistFew;

  /// No description provided for @catalogArtistMany.
  ///
  /// In en, this message translates to:
  /// **'artists'**
  String get catalogArtistMany;

  /// No description provided for @catalogNoGenres.
  ///
  /// In en, this message translates to:
  /// **'No genres yet'**
  String get catalogNoGenres;

  /// No description provided for @catalogBrowseTitle.
  ///
  /// In en, this message translates to:
  /// **'Browse'**
  String get catalogBrowseTitle;

  /// No description provided for @catalogAllGenres.
  ///
  /// In en, this message translates to:
  /// **'All genres'**
  String get catalogAllGenres;

  /// No description provided for @catalogNoArtists.
  ///
  /// In en, this message translates to:
  /// **'No artists'**
  String get catalogNoArtists;

  /// No description provided for @catalogArtistNotFound.
  ///
  /// In en, this message translates to:
  /// **'Artist not in the catalog'**
  String get catalogArtistNotFound;

  /// No description provided for @catalogAlbums.
  ///
  /// In en, this message translates to:
  /// **'Albums'**
  String get catalogAlbums;

  /// No description provided for @catalogEpAndSingles.
  ///
  /// In en, this message translates to:
  /// **'EPs and singles'**
  String get catalogEpAndSingles;

  /// No description provided for @catalogLiveAndCompilations.
  ///
  /// In en, this message translates to:
  /// **'Live and compilations'**
  String get catalogLiveAndCompilations;

  /// No description provided for @catalogListen.
  ///
  /// In en, this message translates to:
  /// **'Listen'**
  String get catalogListen;

  /// No description provided for @catalogPopular.
  ///
  /// In en, this message translates to:
  /// **'Popular'**
  String get catalogPopular;

  /// No description provided for @catalogAllPopular.
  ///
  /// In en, this message translates to:
  /// **'All popular'**
  String get catalogAllPopular;

  /// No description provided for @catalogAllAlbums.
  ///
  /// In en, this message translates to:
  /// **'All albums'**
  String get catalogAllAlbums;

  /// No description provided for @catalogNoAlbums.
  ///
  /// In en, this message translates to:
  /// **'No albums in the catalog'**
  String get catalogNoAlbums;

  /// No description provided for @catalogSimilarArtists.
  ///
  /// In en, this message translates to:
  /// **'Similar artists'**
  String get catalogSimilarArtists;

  /// No description provided for @catalogAboutArtist.
  ///
  /// In en, this message translates to:
  /// **'About the artist'**
  String get catalogAboutArtist;

  /// No description provided for @catalogFollowing.
  ///
  /// In en, this message translates to:
  /// **'Following'**
  String get catalogFollowing;

  /// No description provided for @catalogFollow.
  ///
  /// In en, this message translates to:
  /// **'Follow'**
  String get catalogFollow;

  /// No description provided for @catalogPhotoCredit.
  ///
  /// In en, this message translates to:
  /// **'photo: {credit}'**
  String catalogPhotoCredit(String credit);

  /// No description provided for @catalogCollapse.
  ///
  /// In en, this message translates to:
  /// **'Collapse'**
  String get catalogCollapse;

  /// No description provided for @catalogExpand.
  ///
  /// In en, this message translates to:
  /// **'Expand'**
  String get catalogExpand;

  /// No description provided for @catalogAlbumNotFound.
  ///
  /// In en, this message translates to:
  /// **'Album not found'**
  String get catalogAlbumNotFound;

  /// No description provided for @catalogPlayAlbum.
  ///
  /// In en, this message translates to:
  /// **'Play album'**
  String get catalogPlayAlbum;

  /// No description provided for @catalogOtherEditions.
  ///
  /// In en, this message translates to:
  /// **'Other editions'**
  String get catalogOtherEditions;

  /// No description provided for @catalogArtistNotFoundSongs.
  ///
  /// In en, this message translates to:
  /// **'Artist not found'**
  String get catalogArtistNotFoundSongs;

  /// No description provided for @homeTitle.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get homeTitle;

  /// No description provided for @homeFavorites.
  ///
  /// In en, this message translates to:
  /// **'Favorite songs'**
  String get homeFavorites;

  /// No description provided for @homeEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing yet'**
  String get homeEmpty;

  /// No description provided for @homeTrackOne.
  ///
  /// In en, this message translates to:
  /// **'track'**
  String get homeTrackOne;

  /// No description provided for @homeTrackFew.
  ///
  /// In en, this message translates to:
  /// **'tracks'**
  String get homeTrackFew;

  /// No description provided for @homeTrackMany.
  ///
  /// In en, this message translates to:
  /// **'tracks'**
  String get homeTrackMany;

  /// No description provided for @homePlaylists.
  ///
  /// In en, this message translates to:
  /// **'Playlists'**
  String get homePlaylists;

  /// No description provided for @homePlaylistOne.
  ///
  /// In en, this message translates to:
  /// **'playlist'**
  String get homePlaylistOne;

  /// No description provided for @homePlaylistFew.
  ///
  /// In en, this message translates to:
  /// **'playlists'**
  String get homePlaylistFew;

  /// No description provided for @homePlaylistMany.
  ///
  /// In en, this message translates to:
  /// **'playlists'**
  String get homePlaylistMany;

  /// No description provided for @partsNotFound.
  ///
  /// In en, this message translates to:
  /// **'Not found'**
  String get partsNotFound;

  /// No description provided for @partsServerUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Server unavailable'**
  String get partsServerUnavailable;

  /// No description provided for @partsTooMany.
  ///
  /// In en, this message translates to:
  /// **'Too many requests — wait and try again'**
  String get partsTooMany;

  /// No description provided for @partsNoAnswer.
  ///
  /// In en, this message translates to:
  /// **'The server did not respond'**
  String get partsNoAnswer;

  /// No description provided for @partsNoAccess.
  ///
  /// In en, this message translates to:
  /// **'No access: the build key does not match the server'**
  String get partsNoAccess;

  /// No description provided for @partsConflict.
  ///
  /// In en, this message translates to:
  /// **'The playlist changed — showing the current one'**
  String get partsConflict;

  /// No description provided for @partsDownloads.
  ///
  /// In en, this message translates to:
  /// **'Downloads'**
  String get partsDownloads;

  /// No description provided for @partsRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get partsRetry;

  /// No description provided for @partsReportSend.
  ///
  /// In en, this message translates to:
  /// **'Send report'**
  String get partsReportSend;

  /// No description provided for @partsReportSent.
  ///
  /// In en, this message translates to:
  /// **'Report sent'**
  String get partsReportSent;

  /// No description provided for @partsReportOff.
  ///
  /// In en, this message translates to:
  /// **'Reports are disabled on the server'**
  String get partsReportOff;

  /// No description provided for @partsReportFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not send'**
  String get partsReportFailed;

  /// No description provided for @partsPause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get partsPause;

  /// No description provided for @partsStopLoading.
  ///
  /// In en, this message translates to:
  /// **'Stop loading'**
  String get partsStopLoading;

  /// No description provided for @partsPlay.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get partsPlay;

  /// No description provided for @partsTrackMissing.
  ///
  /// In en, this message translates to:
  /// **'{artist} · not found'**
  String partsTrackMissing(String artist);

  /// No description provided for @partsMore.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get partsMore;

  /// No description provided for @partsPlayNext.
  ///
  /// In en, this message translates to:
  /// **'Play next'**
  String get partsPlayNext;

  /// No description provided for @partsWillPlayNext.
  ///
  /// In en, this message translates to:
  /// **'Plays next'**
  String get partsWillPlayNext;

  /// No description provided for @partsQueueEnd.
  ///
  /// In en, this message translates to:
  /// **'Add to queue'**
  String get partsQueueEnd;

  /// No description provided for @partsOpenArtist.
  ///
  /// In en, this message translates to:
  /// **'Go to artist'**
  String get partsOpenArtist;

  /// No description provided for @partsOpenAlbum.
  ///
  /// In en, this message translates to:
  /// **'Go to album'**
  String get partsOpenAlbum;

  /// No description provided for @partsDownload.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get partsDownload;

  /// No description provided for @partsDeleteFromPhone.
  ///
  /// In en, this message translates to:
  /// **'Delete from phone'**
  String get partsDeleteFromPhone;

  /// No description provided for @partsAddToPlaylist.
  ///
  /// In en, this message translates to:
  /// **'Add to playlist'**
  String get partsAddToPlaylist;

  /// No description provided for @partsRemoveFromPlaylist.
  ///
  /// In en, this message translates to:
  /// **'Remove from playlist'**
  String get partsRemoveFromPlaylist;

  /// No description provided for @partsRemoveFromFavorites.
  ///
  /// In en, this message translates to:
  /// **'Remove from favorites'**
  String get partsRemoveFromFavorites;

  /// No description provided for @partsAddToFavorites.
  ///
  /// In en, this message translates to:
  /// **'Add to favorites'**
  String get partsAddToFavorites;

  /// No description provided for @partsPlaylistGone.
  ///
  /// In en, this message translates to:
  /// **'The playlist is gone'**
  String get partsPlaylistGone;

  /// No description provided for @partsAlbumGone.
  ///
  /// In en, this message translates to:
  /// **'Album not found'**
  String get partsAlbumGone;

  /// No description provided for @partsName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get partsName;

  /// No description provided for @partsCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get partsCancel;

  /// No description provided for @partsDuplicatesTitle.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} song is already in the playlist} other{{count} songs are already in the playlist}}'**
  String partsDuplicatesTitle(int count);

  /// No description provided for @partsDuplicatesAddAll.
  ///
  /// In en, this message translates to:
  /// **'Add all'**
  String get partsDuplicatesAddAll;

  /// No description provided for @partsDuplicatesOnlyNew.
  ///
  /// In en, this message translates to:
  /// **'Only new'**
  String get partsDuplicatesOnlyNew;

  /// No description provided for @partsSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get partsSave;

  /// No description provided for @partsNewPlaylist.
  ///
  /// In en, this message translates to:
  /// **'New playlist'**
  String get partsNewPlaylist;

  /// No description provided for @partsAddedToPlaylist.
  ///
  /// In en, this message translates to:
  /// **'Added to “{name}”'**
  String partsAddedToPlaylist(String name);

  /// No description provided for @partsSongsGone.
  ///
  /// In en, this message translates to:
  /// **'The song or playlist is gone'**
  String get partsSongsGone;

  /// No description provided for @playerUnlike.
  ///
  /// In en, this message translates to:
  /// **'Remove from Favorites'**
  String get playerUnlike;

  /// No description provided for @playerLike.
  ///
  /// In en, this message translates to:
  /// **'Add to Favorites'**
  String get playerLike;

  /// No description provided for @playerNoTrack.
  ///
  /// In en, this message translates to:
  /// **'No track'**
  String get playerNoTrack;

  /// No description provided for @playerCollapse.
  ///
  /// In en, this message translates to:
  /// **'Collapse'**
  String get playerCollapse;

  /// No description provided for @playerMore.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get playerMore;

  /// No description provided for @playerMenuSong.
  ///
  /// In en, this message translates to:
  /// **'Song'**
  String get playerMenuSong;

  /// No description provided for @playerMenuGo.
  ///
  /// In en, this message translates to:
  /// **'Go to'**
  String get playerMenuGo;

  /// No description provided for @playerMenuHelp.
  ///
  /// In en, this message translates to:
  /// **'Help'**
  String get playerMenuHelp;

  /// No description provided for @playerMenuSound.
  ///
  /// In en, this message translates to:
  /// **'Sound'**
  String get playerMenuSound;

  /// No description provided for @playerLosslessOnce.
  ///
  /// In en, this message translates to:
  /// **'Play this song lossless'**
  String get playerLosslessOnce;

  /// No description provided for @playerLosslessMissed.
  ///
  /// In en, this message translates to:
  /// **'No lossless copy of this song was found'**
  String get playerLosslessMissed;

  /// No description provided for @playerUndislike.
  ///
  /// In en, this message translates to:
  /// **'Remove “Dislike”'**
  String get playerUndislike;

  /// No description provided for @playerToPodcast.
  ///
  /// In en, this message translates to:
  /// **'Go to podcast'**
  String get playerToPodcast;

  /// No description provided for @playerAddToPlaylist.
  ///
  /// In en, this message translates to:
  /// **'Add to playlist'**
  String get playerAddToPlaylist;

  /// No description provided for @playerAddedToDownloads.
  ///
  /// In en, this message translates to:
  /// **'Added to Downloads'**
  String get playerAddedToDownloads;

  /// No description provided for @playerDownload.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get playerDownload;

  /// No description provided for @playerShuffle.
  ///
  /// In en, this message translates to:
  /// **'Shuffle'**
  String get playerShuffle;

  /// No description provided for @playerPrevious.
  ///
  /// In en, this message translates to:
  /// **'Previous'**
  String get playerPrevious;

  /// No description provided for @playerNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get playerNext;

  /// No description provided for @playerRepeatOff.
  ///
  /// In en, this message translates to:
  /// **'Repeat off'**
  String get playerRepeatOff;

  /// No description provided for @playerRepeatAll.
  ///
  /// In en, this message translates to:
  /// **'Repeat all'**
  String get playerRepeatAll;

  /// No description provided for @playerRepeatOne.
  ///
  /// In en, this message translates to:
  /// **'Repeat one'**
  String get playerRepeatOne;

  /// No description provided for @playerQueue.
  ///
  /// In en, this message translates to:
  /// **'Queue'**
  String get playerQueue;

  /// No description provided for @playerWaitSeconds.
  ///
  /// In en, this message translates to:
  /// **' · {seconds}s'**
  String playerWaitSeconds(int seconds);

  /// No description provided for @miniSearchingSource.
  ///
  /// In en, this message translates to:
  /// **'Looking for source'**
  String get miniSearchingSource;

  /// No description provided for @miniPreparingAudio.
  ///
  /// In en, this message translates to:
  /// **'Preparing audio'**
  String get miniPreparingAudio;

  /// No description provided for @miniNoSource.
  ///
  /// In en, this message translates to:
  /// **'Source not found — retry'**
  String get miniNoSource;

  /// No description provided for @miniUnknownTrack.
  ///
  /// In en, this message translates to:
  /// **'Track not found on server — search again'**
  String get miniUnknownTrack;

  /// No description provided for @miniNoAccess.
  ///
  /// In en, this message translates to:
  /// **'Access denied — check build key'**
  String get miniNoAccess;

  /// No description provided for @miniNoAnswer.
  ///
  /// In en, this message translates to:
  /// **'Server timed out — retry'**
  String get miniNoAnswer;

  /// No description provided for @miniDropped.
  ///
  /// In en, this message translates to:
  /// **'Connection lost — retry'**
  String get miniDropped;

  /// No description provided for @miniFailed.
  ///
  /// In en, this message translates to:
  /// **'Playback failed — retry'**
  String get miniFailed;

  /// No description provided for @miniWaitSeconds.
  ///
  /// In en, this message translates to:
  /// **' · {seconds}s'**
  String miniWaitSeconds(int seconds);

  /// No description provided for @libraryTitle.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get libraryTitle;

  /// No description provided for @libraryFavorites.
  ///
  /// In en, this message translates to:
  /// **'Favorite songs'**
  String get libraryFavorites;

  /// No description provided for @libraryTracksCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} track} other{{count} tracks}}'**
  String libraryTracksCount(int count);

  /// No description provided for @libraryMediaSection.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get libraryMediaSection;

  /// No description provided for @libraryRatingsSection.
  ///
  /// In en, this message translates to:
  /// **'My ratings'**
  String get libraryRatingsSection;

  /// No description provided for @libraryHistorySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get libraryHistorySubtitle;

  /// No description provided for @libraryDownloadsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get libraryDownloadsSubtitle;

  /// No description provided for @libraryHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get libraryHistory;

  /// No description provided for @libraryPlaylists.
  ///
  /// In en, this message translates to:
  /// **'Playlists'**
  String get libraryPlaylists;

  /// No description provided for @libraryPlaylistsCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} playlist} other{{count} playlists}}'**
  String libraryPlaylistsCount(int count);

  /// No description provided for @libraryDownloads.
  ///
  /// In en, this message translates to:
  /// **'Downloads'**
  String get libraryDownloads;

  /// No description provided for @libraryDevice.
  ///
  /// In en, this message translates to:
  /// **'Device music'**
  String get libraryDevice;

  /// No description provided for @libraryDeviceSubtitle.
  ///
  /// In en, this message translates to:
  /// **'From storage'**
  String get libraryDeviceSubtitle;

  /// No description provided for @libraryDeviceTile.
  ///
  /// In en, this message translates to:
  /// **'On this phone'**
  String get libraryDeviceTile;

  /// No description provided for @libraryImport.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get libraryImport;

  /// No description provided for @libraryImportSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Spotify, Apple Music, M3U, text'**
  String get libraryImportSubtitle;

  /// No description provided for @libraryFavoritesEmpty.
  ///
  /// In en, this message translates to:
  /// **'No Favorites yet'**
  String get libraryFavoritesEmpty;

  /// No description provided for @libraryHistoryEmpty.
  ///
  /// In en, this message translates to:
  /// **'History is empty'**
  String get libraryHistoryEmpty;

  /// No description provided for @libraryNewPlaylist.
  ///
  /// In en, this message translates to:
  /// **'New playlist'**
  String get libraryNewPlaylist;

  /// No description provided for @libraryPlaylistNotFound.
  ///
  /// In en, this message translates to:
  /// **'Playlist no longer exists'**
  String get libraryPlaylistNotFound;

  /// No description provided for @libraryRename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get libraryRename;

  /// No description provided for @libraryDeletePlaylistConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"?'**
  String libraryDeletePlaylistConfirm(String name);

  /// No description provided for @libraryDeletePlaylistMessage.
  ///
  /// In en, this message translates to:
  /// **'Songs will remain in the catalog and favorites.'**
  String get libraryDeletePlaylistMessage;

  /// No description provided for @libraryCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get libraryCancel;

  /// No description provided for @libraryDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get libraryDelete;

  /// No description provided for @libraryDeletePlaylist.
  ///
  /// In en, this message translates to:
  /// **'Delete playlist'**
  String get libraryDeletePlaylist;

  /// No description provided for @libraryPlaylistEmpty.
  ///
  /// In en, this message translates to:
  /// **'Empty. Add songs from search or albums'**
  String get libraryPlaylistEmpty;

  /// No description provided for @libraryPlayPlaylist.
  ///
  /// In en, this message translates to:
  /// **'Play playlist'**
  String get libraryPlayPlaylist;

  /// No description provided for @memoryGigabytes.
  ///
  /// In en, this message translates to:
  /// **'{gb} GB'**
  String memoryGigabytes(String gb);

  /// No description provided for @memoryDeleteAllTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete all downloads?'**
  String get memoryDeleteAllTitle;

  /// No description provided for @memoryDeleteAllMessage.
  ///
  /// In en, this message translates to:
  /// **'All downloaded songs will be deleted from your phone.'**
  String get memoryDeleteAllMessage;

  /// No description provided for @memoryCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get memoryCancel;

  /// No description provided for @memoryDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get memoryDelete;

  /// No description provided for @memoryTitle.
  ///
  /// In en, this message translates to:
  /// **'Storage'**
  String get memoryTitle;

  /// No description provided for @memoryLegendDownloaded.
  ///
  /// In en, this message translates to:
  /// **'Downloaded · {size}'**
  String memoryLegendDownloaded(String size);

  /// No description provided for @memoryLegendReserve.
  ///
  /// In en, this message translates to:
  /// **'Played cache · {size}'**
  String memoryLegendReserve(String size);

  /// No description provided for @memoryLegendFree.
  ///
  /// In en, this message translates to:
  /// **'Free · {size}'**
  String memoryLegendFree(String size);

  /// No description provided for @memoryReserveTitle.
  ///
  /// In en, this message translates to:
  /// **'Cache of played songs'**
  String get memoryReserveTitle;

  /// No description provided for @memoryReserveOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get memoryReserveOff;

  /// No description provided for @memoryClearReserve.
  ///
  /// In en, this message translates to:
  /// **'Clear cache'**
  String get memoryClearReserve;

  /// No description provided for @memoryDeleteAll.
  ///
  /// In en, this message translates to:
  /// **'Delete all downloads'**
  String get memoryDeleteAll;

  /// No description provided for @navHome.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get navHome;

  /// No description provided for @navBrowse.
  ///
  /// In en, this message translates to:
  /// **'Browse'**
  String get navBrowse;

  /// No description provided for @navNews.
  ///
  /// In en, this message translates to:
  /// **'News'**
  String get navNews;

  /// No description provided for @navSearch.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get navSearch;

  /// No description provided for @navLibrary.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get navLibrary;

  /// No description provided for @newsTitle.
  ///
  /// In en, this message translates to:
  /// **'News'**
  String get newsTitle;

  /// No description provided for @newsConsentDescription.
  ///
  /// In en, this message translates to:
  /// **'News comes from this server and its sources. To build the feed, the server connects to the internet directly. Your phone does not connect outside.'**
  String get newsConsentDescription;

  /// No description provided for @newsConsentGotIt.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get newsConsentGotIt;

  /// No description provided for @newsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'News unavailable'**
  String get newsUnavailable;

  /// No description provided for @newsServerDisabled.
  ///
  /// In en, this message translates to:
  /// **'News: disabled on this server'**
  String get newsServerDisabled;

  /// No description provided for @newsReadFull.
  ///
  /// In en, this message translates to:
  /// **'Read in full'**
  String get newsReadFull;

  /// No description provided for @newsSource.
  ///
  /// In en, this message translates to:
  /// **'Source'**
  String get newsSource;

  /// No description provided for @newsPlay.
  ///
  /// In en, this message translates to:
  /// **'Listen'**
  String get newsPlay;

  /// No description provided for @newsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No news yet'**
  String get newsEmpty;

  /// No description provided for @newsSuggestionsTitle.
  ///
  /// In en, this message translates to:
  /// **'You often listen to'**
  String get newsSuggestionsTitle;

  /// No description provided for @newsFollowAll.
  ///
  /// In en, this message translates to:
  /// **'Follow all'**
  String get newsFollowAll;

  /// No description provided for @newsChannels.
  ///
  /// In en, this message translates to:
  /// **'Channels'**
  String get newsChannels;

  /// No description provided for @channelsTitle.
  ///
  /// In en, this message translates to:
  /// **'Channels'**
  String get channelsTitle;

  /// No description provided for @channelsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Channels unavailable'**
  String get channelsUnavailable;

  /// No description provided for @channelsAddErrorNotPublic.
  ///
  /// In en, this message translates to:
  /// **'This is a private network address — the channel cannot be added'**
  String get channelsAddErrorNotPublic;

  /// No description provided for @channelsAddErrorTooMany.
  ///
  /// In en, this message translates to:
  /// **'Channel limit reached'**
  String get channelsAddErrorTooMany;

  /// No description provided for @channelsAddErrorNotFeed.
  ///
  /// In en, this message translates to:
  /// **'No news feed found at this link'**
  String get channelsAddErrorNotFeed;

  /// No description provided for @channelsAddErrorFailed.
  ///
  /// In en, this message translates to:
  /// **'The server did not answer'**
  String get channelsAddErrorFailed;

  /// No description provided for @channelsCuratedHeading.
  ///
  /// In en, this message translates to:
  /// **'Curated channels'**
  String get channelsCuratedHeading;

  /// No description provided for @channelsOwnHeading.
  ///
  /// In en, this message translates to:
  /// **'Your channels'**
  String get channelsOwnHeading;

  /// No description provided for @channelsOwnEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing yet'**
  String get channelsOwnEmpty;

  /// No description provided for @channelsAddHeading.
  ///
  /// In en, this message translates to:
  /// **'Add by link'**
  String get channelsAddHeading;

  /// No description provided for @channelsAddLinkHint.
  ///
  /// In en, this message translates to:
  /// **'Link: @channel, t.me/… or a site'**
  String get channelsAddLinkHint;

  /// No description provided for @channelsAddButton.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get channelsAddButton;

  /// No description provided for @channelsPopularHeading.
  ///
  /// In en, this message translates to:
  /// **'Popular on this server'**
  String get channelsPopularHeading;

  /// No description provided for @channelsPopularEmpty.
  ///
  /// In en, this message translates to:
  /// **'Channels added by at least three people will show up here'**
  String get channelsPopularEmpty;

  /// No description provided for @channelsPopularAdded.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} person added it} other{{count} people added it}}'**
  String channelsPopularAdded(int count);

  /// No description provided for @downloadsTitle.
  ///
  /// In en, this message translates to:
  /// **'Downloads'**
  String get downloadsTitle;

  /// No description provided for @downloadsProgress.
  ///
  /// In en, this message translates to:
  /// **'Downloaded {done} of {total}'**
  String downloadsProgress(int done, int total);

  /// No description provided for @downloadsFree.
  ///
  /// In en, this message translates to:
  /// **'{size} GB free'**
  String downloadsFree(int size);

  /// No description provided for @downloadsHoldMetered.
  ///
  /// In en, this message translates to:
  /// **'Paused: downloading over mobile data is off'**
  String get downloadsHoldMetered;

  /// No description provided for @downloadsHoldNoRoom.
  ///
  /// In en, this message translates to:
  /// **'Paused: not enough free space on the phone'**
  String get downloadsHoldNoRoom;

  /// No description provided for @downloadsAllowMobile.
  ///
  /// In en, this message translates to:
  /// **'Download over mobile data'**
  String get downloadsAllowMobile;

  /// No description provided for @downloadsMemoryOf.
  ///
  /// In en, this message translates to:
  /// **'Storage · {used} of {total}'**
  String downloadsMemoryOf(String used, String total);

  /// No description provided for @downloadsMemory.
  ///
  /// In en, this message translates to:
  /// **'Storage · {used}'**
  String downloadsMemory(String used);

  /// No description provided for @downloadsEpisodes.
  ///
  /// In en, this message translates to:
  /// **'Podcast episodes'**
  String get downloadsEpisodes;

  /// No description provided for @downloadsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No downloads yet'**
  String get downloadsEmpty;

  /// No description provided for @downloadsSizeMb.
  ///
  /// In en, this message translates to:
  /// **'{size} MB'**
  String downloadsSizeMb(String size);

  /// No description provided for @downloadsRemove.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get downloadsRemove;

  /// No description provided for @downloadsDownloadAll.
  ///
  /// In en, this message translates to:
  /// **'Download all'**
  String get downloadsDownloadAll;

  /// No description provided for @downloadsDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading {done} of {total}'**
  String downloadsDownloading(int done, int total);

  /// No description provided for @downloadsOnPhone.
  ///
  /// In en, this message translates to:
  /// **'On the phone'**
  String get downloadsOnPhone;

  /// No description provided for @downloadsOnPhoneDetail.
  ///
  /// In en, this message translates to:
  /// **'On the phone: {songs} · {size} MB'**
  String downloadsOnPhoneDetail(String songs, int size);

  /// No description provided for @downloadsSongs.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one {{count} song} other {{count} songs}}'**
  String downloadsSongs(int count);

  /// No description provided for @downloadsRemoveFromPhone.
  ///
  /// In en, this message translates to:
  /// **'Remove from phone'**
  String get downloadsRemoveFromPhone;

  /// No description provided for @downloadsNotificationProgress.
  ///
  /// In en, this message translates to:
  /// **'Downloading {numFinished} of {numTotal}'**
  String downloadsNotificationProgress(String numFinished, String numTotal);

  /// No description provided for @downloadsNotificationComplete.
  ///
  /// In en, this message translates to:
  /// **'Download complete'**
  String get downloadsNotificationComplete;

  /// No description provided for @storageTitle.
  ///
  /// In en, this message translates to:
  /// **'Space for music'**
  String get storageTitle;

  /// No description provided for @storageDescription.
  ///
  /// In en, this message translates to:
  /// **'Songs you play stay on the phone, so replays don\'t use data. 0 keeps nothing; change the size later in Downloads.'**
  String get storageDescription;

  /// No description provided for @storageNoRoom.
  ///
  /// In en, this message translates to:
  /// **'Almost no free space — keeping played songs is off.'**
  String get storageNoRoom;

  /// No description provided for @storageValue.
  ///
  /// In en, this message translates to:
  /// **'{count} GB'**
  String storageValue(int count);

  /// No description provided for @storageNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get storageNext;

  /// No description provided for @storageHintFits.
  ///
  /// In en, this message translates to:
  /// **'≈ {flac} songs in FLAC / {opus} in Opus'**
  String storageHintFits(int flac, int opus);

  /// No description provided for @storageHintNothing.
  ///
  /// In en, this message translates to:
  /// **'Not enough room for a single song'**
  String get storageHintNothing;

  /// No description provided for @importFileTooLarge.
  ///
  /// In en, this message translates to:
  /// **'File is larger than 10 MiB. Choose a smaller file.'**
  String get importFileTooLarge;

  /// No description provided for @importChooseTrack.
  ///
  /// In en, this message translates to:
  /// **'Choose a song'**
  String get importChooseTrack;

  /// No description provided for @importNone.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get importNone;

  /// No description provided for @importCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get importCancel;

  /// No description provided for @importDescription.
  ///
  /// In en, this message translates to:
  /// **'Transfer your music: Spotify — CSV or ZIP from Exportify; Apple Music — library XML; M3U/M3U8 or \"artist — song\" lines. Yandex — via TuneMyMusic in CSV.'**
  String get importDescription;

  /// No description provided for @importPickFile.
  ///
  /// In en, this message translates to:
  /// **'Choose file'**
  String get importPickFile;

  /// No description provided for @importPasteText.
  ///
  /// In en, this message translates to:
  /// **'Paste text'**
  String get importPasteText;

  /// No description provided for @importTextHint.
  ///
  /// In en, this message translates to:
  /// **'Artist — song, one per line'**
  String get importTextHint;

  /// No description provided for @importSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get importSend;

  /// No description provided for @importSaveAll.
  ///
  /// In en, this message translates to:
  /// **'Save all'**
  String get importSaveAll;

  /// No description provided for @importListFound.
  ///
  /// In en, this message translates to:
  /// **'{found} of {total} found'**
  String importListFound(int found, int total);

  /// No description provided for @importSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get importSaved;

  /// No description provided for @importNotFound.
  ///
  /// In en, this message translates to:
  /// **'Not found'**
  String get importNotFound;

  /// No description provided for @importSelected.
  ///
  /// In en, this message translates to:
  /// **'Selected'**
  String get importSelected;

  /// No description provided for @importDoubtful.
  ///
  /// In en, this message translates to:
  /// **'Doubtful'**
  String get importDoubtful;

  /// No description provided for @importFound.
  ///
  /// In en, this message translates to:
  /// **'Found'**
  String get importFound;

  /// No description provided for @importSummary.
  ///
  /// In en, this message translates to:
  /// **'{found} of {total} found · {doubtful} doubtful · {missing} missing'**
  String importSummary(int found, int total, int doubtful, int missing);

  /// No description provided for @importToFavorites.
  ///
  /// In en, this message translates to:
  /// **'Add to Favorites'**
  String get importToFavorites;

  /// No description provided for @importSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get importSave;

  /// No description provided for @importDoubtfulHint.
  ///
  /// In en, this message translates to:
  /// **'Checking doubtful songs is optional. Missing songs stay dimmed in the playlist; only found ones go to Favorites.'**
  String get importDoubtfulHint;

  /// No description provided for @importTitle.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get importTitle;

  /// No description provided for @accountTitle.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get accountTitle;

  /// No description provided for @accountAutoReports.
  ///
  /// In en, this message translates to:
  /// **'Send reports automatically'**
  String get accountAutoReports;

  /// No description provided for @accountNews.
  ///
  /// In en, this message translates to:
  /// **'News'**
  String get accountNews;

  /// No description provided for @accountScrobble.
  ///
  /// In en, this message translates to:
  /// **'ListenBrainz and Last.fm'**
  String get accountScrobble;

  /// No description provided for @accountLogout.
  ///
  /// In en, this message translates to:
  /// **'Log out'**
  String get accountLogout;

  /// No description provided for @accountSwitchServer.
  ///
  /// In en, this message translates to:
  /// **'Switch server'**
  String get accountSwitchServer;

  /// No description provided for @accountLogoutConfirm.
  ///
  /// In en, this message translates to:
  /// **'Log out?'**
  String get accountLogoutConfirm;

  /// No description provided for @accountSwitchServerConfirm.
  ///
  /// In en, this message translates to:
  /// **'Switch server?'**
  String get accountSwitchServerConfirm;

  /// No description provided for @accountAutoReportsConfirm.
  ///
  /// In en, this message translates to:
  /// **'Send reports automatically?'**
  String get accountAutoReportsConfirm;

  /// No description provided for @accountAutoReportsDescription.
  ///
  /// In en, this message translates to:
  /// **'When the app crashes, it will send a short report to your server automatically: what broke, on which screen and where in the code. No song titles, search queries or phone address.'**
  String get accountAutoReportsDescription;

  /// No description provided for @accountCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get accountCancel;

  /// No description provided for @accountSendReports.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get accountSendReports;

  /// No description provided for @accountLeaveWarning.
  ///
  /// In en, this message translates to:
  /// **'You will need to enter your password again to come back.'**
  String get accountLeaveWarning;

  /// No description provided for @appPlayNext.
  ///
  /// In en, this message translates to:
  /// **'Playing next'**
  String get appPlayNext;

  /// No description provided for @appEnqueued.
  ///
  /// In en, this message translates to:
  /// **'Added to queue'**
  String get appEnqueued;

  /// No description provided for @appPlaybackChannel.
  ///
  /// In en, this message translates to:
  /// **'Playback'**
  String get appPlaybackChannel;

  /// No description provided for @sleepTimerTitle.
  ///
  /// In en, this message translates to:
  /// **'Sleep timer'**
  String get sleepTimerTitle;

  /// No description provided for @sleepTimer15Min.
  ///
  /// In en, this message translates to:
  /// **'15 min'**
  String get sleepTimer15Min;

  /// No description provided for @sleepTimer30Min.
  ///
  /// In en, this message translates to:
  /// **'30 min'**
  String get sleepTimer30Min;

  /// No description provided for @sleepTimer45Min.
  ///
  /// In en, this message translates to:
  /// **'45 min'**
  String get sleepTimer45Min;

  /// No description provided for @sleepTimer60Min.
  ///
  /// In en, this message translates to:
  /// **'1 hour'**
  String get sleepTimer60Min;

  /// No description provided for @sleepTimerEndOfSong.
  ///
  /// In en, this message translates to:
  /// **'End of song'**
  String get sleepTimerEndOfSong;

  /// Remaining sleep timer duration in minutes
  ///
  /// In en, this message translates to:
  /// **'{n, plural, one{{n} min left} other{{n} min left}}'**
  String sleepTimerMinLeft(int n);

  /// No description provided for @sleepTimerTurnOff.
  ///
  /// In en, this message translates to:
  /// **'Turn off'**
  String get sleepTimerTurnOff;

  /// No description provided for @equalizerTitle.
  ///
  /// In en, this message translates to:
  /// **'Equalizer'**
  String get equalizerTitle;

  /// No description provided for @equalizerFlat.
  ///
  /// In en, this message translates to:
  /// **'Flat'**
  String get equalizerFlat;

  /// No description provided for @equalizerBass.
  ///
  /// In en, this message translates to:
  /// **'Bass'**
  String get equalizerBass;

  /// No description provided for @equalizerTreble.
  ///
  /// In en, this message translates to:
  /// **'Treble'**
  String get equalizerTreble;

  /// No description provided for @equalizerVocal.
  ///
  /// In en, this message translates to:
  /// **'Vocal'**
  String get equalizerVocal;

  /// No description provided for @equalizerWaiting.
  ///
  /// In en, this message translates to:
  /// **'The equalizer will set up with the first song'**
  String get equalizerWaiting;

  /// No description provided for @equalizerMissing.
  ///
  /// In en, this message translates to:
  /// **'This phone has no equalizer'**
  String get equalizerMissing;

  /// No description provided for @equalizerHz.
  ///
  /// In en, this message translates to:
  /// **'{value} Hz'**
  String equalizerHz(String value);

  /// No description provided for @equalizerKhz.
  ///
  /// In en, this message translates to:
  /// **'{value} kHz'**
  String equalizerKhz(String value);

  /// No description provided for @lyricsNone.
  ///
  /// In en, this message translates to:
  /// **'No lyrics for this song yet'**
  String get lyricsNone;

  /// No description provided for @aboutTitle.
  ///
  /// In en, this message translates to:
  /// **'About the app'**
  String get aboutTitle;

  /// No description provided for @aboutCredits.
  ///
  /// In en, this message translates to:
  /// **'Thank you to the projects this app is built on:\n\n• Lyrics — LRCLIB\n• Music catalog — MusicBrainz\n• Album covers — Cover Art Archive\n• Artist photos — Wikimedia Commons, with the author and licence under each photo'**
  String get aboutCredits;

  /// No description provided for @aboutLicenses.
  ///
  /// In en, this message translates to:
  /// **'Licences'**
  String get aboutLicenses;

  /// No description provided for @aboutClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get aboutClose;

  /// No description provided for @lyricsCredit.
  ///
  /// In en, this message translates to:
  /// **'Lyrics: LRCLIB'**
  String get lyricsCredit;

  /// No description provided for @lyricsInstrumental.
  ///
  /// In en, this message translates to:
  /// **'Instrumental'**
  String get lyricsInstrumental;

  /// No description provided for @problemTitle.
  ///
  /// In en, this message translates to:
  /// **'Report a problem'**
  String get problemTitle;

  /// No description provided for @problemReasonWrongTrack.
  ///
  /// In en, this message translates to:
  /// **'Wrong song plays'**
  String get problemReasonWrongTrack;

  /// No description provided for @problemReasonNoPlay.
  ///
  /// In en, this message translates to:
  /// **'Doesn\'t play'**
  String get problemReasonNoPlay;

  /// No description provided for @problemReasonBadSound.
  ///
  /// In en, this message translates to:
  /// **'Bad sound'**
  String get problemReasonBadSound;

  /// No description provided for @problemReasonCover.
  ///
  /// In en, this message translates to:
  /// **'Wrong or missing cover'**
  String get problemReasonCover;

  /// No description provided for @problemReasonWrongName.
  ///
  /// In en, this message translates to:
  /// **'Wrong title or name'**
  String get problemReasonWrongName;

  /// No description provided for @problemReasonOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get problemReasonOther;

  /// No description provided for @problemTextHint.
  ///
  /// In en, this message translates to:
  /// **'A few words, if you like'**
  String get problemTextHint;

  /// No description provided for @problemSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get problemSend;

  /// No description provided for @problemSent.
  ///
  /// In en, this message translates to:
  /// **'Thanks, report sent'**
  String get problemSent;

  /// No description provided for @problemTooMany.
  ///
  /// In en, this message translates to:
  /// **'Too many reports. Try again in an hour.'**
  String get problemTooMany;

  /// No description provided for @problemFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not send. Try again.'**
  String get problemFailed;

  /// No description provided for @deviceTabSongs.
  ///
  /// In en, this message translates to:
  /// **'Songs'**
  String get deviceTabSongs;

  /// No description provided for @deviceTabAlbums.
  ///
  /// In en, this message translates to:
  /// **'Albums'**
  String get deviceTabAlbums;

  /// No description provided for @deviceTabArtists.
  ///
  /// In en, this message translates to:
  /// **'Artists'**
  String get deviceTabArtists;

  /// No description provided for @deviceTabFolders.
  ///
  /// In en, this message translates to:
  /// **'Folders'**
  String get deviceTabFolders;

  /// No description provided for @deviceNoAccess.
  ///
  /// In en, this message translates to:
  /// **'To show the music on this phone, the app needs permission.'**
  String get deviceNoAccess;

  /// No description provided for @deviceAllow.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get deviceAllow;

  /// No description provided for @deviceDeniedForever.
  ///
  /// In en, this message translates to:
  /// **'Access to music is denied. You can allow it in the phone settings.'**
  String get deviceDeniedForever;

  /// No description provided for @deviceOpenSettings.
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get deviceOpenSettings;

  /// No description provided for @deviceEmpty.
  ///
  /// In en, this message translates to:
  /// **'No music found on this phone'**
  String get deviceEmpty;

  /// No description provided for @deviceFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not read the music on this phone'**
  String get deviceFailed;

  /// No description provided for @deviceRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get deviceRefresh;

  /// No description provided for @deviceRefreshFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not refresh the list'**
  String get deviceRefreshFailed;

  /// No description provided for @deviceUntitled.
  ///
  /// In en, this message translates to:
  /// **'Untitled'**
  String get deviceUntitled;

  /// No description provided for @deviceBack.
  ///
  /// In en, this message translates to:
  /// **'Back to the list'**
  String get deviceBack;

  /// No description provided for @deviceTabEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing here yet'**
  String get deviceTabEmpty;

  /// No description provided for @deviceSongCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} song} other{{count} songs}}'**
  String deviceSongCount(int count);

  /// No description provided for @podcastsTitle.
  ///
  /// In en, this message translates to:
  /// **'Podcasts'**
  String get podcastsTitle;

  /// No description provided for @browseBooks.
  ///
  /// In en, this message translates to:
  /// **'Audiobooks'**
  String get browseBooks;

  /// No description provided for @browseNotSetUp.
  ///
  /// In en, this message translates to:
  /// **'Not set up on the server'**
  String get browseNotSetUp;

  /// No description provided for @audiobooksTitle.
  ///
  /// In en, this message translates to:
  /// **'Audiobooks'**
  String get audiobooksTitle;

  /// No description provided for @podcastsSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Find a podcast'**
  String get podcastsSearchHint;

  /// No description provided for @podcastsLanguages.
  ///
  /// In en, this message translates to:
  /// **'Languages'**
  String get podcastsLanguages;

  /// No description provided for @podcastsContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get podcastsContinue;

  /// No description provided for @podcastsNewEpisodes.
  ///
  /// In en, this message translates to:
  /// **'New episodes'**
  String get podcastsNewEpisodes;

  /// No description provided for @podcastsSubscriptions.
  ///
  /// In en, this message translates to:
  /// **'Subscriptions'**
  String get podcastsSubscriptions;

  /// No description provided for @podcastsPopular.
  ///
  /// In en, this message translates to:
  /// **'Popular'**
  String get podcastsPopular;

  /// No description provided for @podcastsCategories.
  ///
  /// In en, this message translates to:
  /// **'Categories'**
  String get podcastsCategories;

  /// No description provided for @podcastsSubscribe.
  ///
  /// In en, this message translates to:
  /// **'Subscribe'**
  String get podcastsSubscribe;

  /// No description provided for @podcastsSubscribed.
  ///
  /// In en, this message translates to:
  /// **'Subscribed'**
  String get podcastsSubscribed;

  /// No description provided for @podcastsSubscribeFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t subscribe. Try again.'**
  String get podcastsSubscribeFailed;

  /// No description provided for @podcastsSearchFailed.
  ///
  /// In en, this message translates to:
  /// **'Search failed. Check the connection.'**
  String get podcastsSearchFailed;

  /// No description provided for @podcastsNothingFound.
  ///
  /// In en, this message translates to:
  /// **'Nothing found'**
  String get podcastsNothingFound;

  /// No description provided for @podcastsSearchAllLanguages.
  ///
  /// In en, this message translates to:
  /// **'Search in all languages'**
  String get podcastsSearchAllLanguages;

  /// No description provided for @podcastsLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load podcasts'**
  String get podcastsLoadFailed;

  /// No description provided for @podcastsRetry.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get podcastsRetry;

  /// No description provided for @podcastsEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing here yet'**
  String get podcastsEmpty;

  /// No description provided for @podcastsAllLanguages.
  ///
  /// In en, this message translates to:
  /// **'All languages'**
  String get podcastsAllLanguages;

  /// No description provided for @podcastAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get podcastAbout;

  /// No description provided for @podcastEpisodes.
  ///
  /// In en, this message translates to:
  /// **'Episodes'**
  String get podcastEpisodes;

  /// No description provided for @podcastNewestFirst.
  ///
  /// In en, this message translates to:
  /// **'Newest first'**
  String get podcastNewestFirst;

  /// No description provided for @podcastOldestFirst.
  ///
  /// In en, this message translates to:
  /// **'Oldest first'**
  String get podcastOldestFirst;

  /// No description provided for @podcastNoEpisodes.
  ///
  /// In en, this message translates to:
  /// **'No episodes yet'**
  String get podcastNoEpisodes;

  /// No description provided for @podcastUntitled.
  ///
  /// In en, this message translates to:
  /// **'Untitled episode'**
  String get podcastUntitled;

  /// No description provided for @podcastDownload.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get podcastDownload;

  /// No description provided for @podcastDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading'**
  String get podcastDownloading;

  /// No description provided for @podcastOnPhone.
  ///
  /// In en, this message translates to:
  /// **'On the phone'**
  String get podcastOnPhone;

  /// No description provided for @podcastDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed'**
  String get podcastDownloadFailed;

  /// No description provided for @podcastNoRoom.
  ///
  /// In en, this message translates to:
  /// **'Not enough space on the phone'**
  String get podcastNoRoom;

  /// No description provided for @podcastMetered.
  ///
  /// In en, this message translates to:
  /// **'Downloads over mobile data are off'**
  String get podcastMetered;

  /// No description provided for @podcastPlay.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get podcastPlay;

  /// No description provided for @podcastEpisodesFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load episodes'**
  String get podcastEpisodesFailed;

  /// No description provided for @podcastHoursMinutes.
  ///
  /// In en, this message translates to:
  /// **'{hours} h {minutes} min'**
  String podcastHoursMinutes(int hours, int minutes);

  /// No description provided for @podcastMinutes.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min'**
  String podcastMinutes(int minutes);

  /// TalkBack label: rewind a podcast episode 15 seconds
  ///
  /// In en, this message translates to:
  /// **'Back 15 seconds'**
  String get playerSkipBack;

  /// TalkBack label: skip a podcast episode ahead 30 seconds
  ///
  /// In en, this message translates to:
  /// **'Forward 30 seconds'**
  String get playerSkipForward;

  /// TalkBack label of the podcast speed button, followed by the current speed like 1.5×
  ///
  /// In en, this message translates to:
  /// **'Speed'**
  String get playerSpeed;

  /// No description provided for @knownAsHeading.
  ///
  /// In en, this message translates to:
  /// **'Also known as'**
  String get knownAsHeading;

  /// No description provided for @knownAsSpoken.
  ///
  /// In en, this message translates to:
  /// **'Also known as {name}'**
  String knownAsSpoken(String name);

  /// Sheet after a crash (FT-698)
  ///
  /// In en, this message translates to:
  /// **'The app closed with an error last time'**
  String get crashTitle;

  /// No description provided for @crashBody.
  ///
  /// In en, this message translates to:
  /// **'Send a report? It holds only places in the code: no songs, searches or addresses.'**
  String get crashBody;

  /// No description provided for @crashSend.
  ///
  /// In en, this message translates to:
  /// **'Send report'**
  String get crashSend;

  /// No description provided for @crashSkip.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get crashSkip;

  /// No description provided for @crashNever.
  ///
  /// In en, this message translates to:
  /// **'Don\'t ask again'**
  String get crashNever;

  /// No description provided for @crashSent.
  ///
  /// In en, this message translates to:
  /// **'Report sent'**
  String get crashSent;

  /// No description provided for @crashNotSent.
  ///
  /// In en, this message translates to:
  /// **'Report not sent'**
  String get crashNotSent;

  /// Label for the speed tile on podcast player
  ///
  /// In en, this message translates to:
  /// **'Speed'**
  String get spokenSpeed;

  /// Label for the download tile on podcast player
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get spokenDownload;

  /// Label for the downloaded tile on podcast player
  ///
  /// In en, this message translates to:
  /// **'Downloaded'**
  String get spokenDownloaded;

  /// Label for the sleep timer tile on podcast player
  ///
  /// In en, this message translates to:
  /// **'Sleep timer'**
  String get spokenSleep;

  /// Label for the queue tile on podcast player
  ///
  /// In en, this message translates to:
  /// **'Queue'**
  String get spokenQueue;

  /// Label for the parts tile on spoken player
  ///
  /// In en, this message translates to:
  /// **'Parts'**
  String get spokenParts;

  /// Label for the remaining tile on spoken player
  ///
  /// In en, this message translates to:
  /// **'Left'**
  String get spokenRemaining;

  /// Remaining duration in minutes on spoken player
  ///
  /// In en, this message translates to:
  /// **'{m} min'**
  String spokenRemainingMinutes(int m);

  /// Remaining duration in hours and minutes on spoken player
  ///
  /// In en, this message translates to:
  /// **'{h} h {m} min'**
  String spokenRemainingHoursMinutes(int h, int m);

  /// No description provided for @libraryBooks.
  ///
  /// In en, this message translates to:
  /// **'Audiobooks'**
  String get libraryBooks;

  /// No description provided for @booksSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Title or author'**
  String get booksSearchHint;

  /// No description provided for @booksShelfTitle.
  ///
  /// In en, this message translates to:
  /// **'My shelf'**
  String get booksShelfTitle;

  /// No description provided for @booksEmptyShelf.
  ///
  /// In en, this message translates to:
  /// **'Your shelf is empty.\nFind a book in the search above and tap “To shelf”.'**
  String get booksEmptyShelf;

  /// No description provided for @booksLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load shelf'**
  String get booksLoadFailed;

  /// No description provided for @booksRetry.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get booksRetry;

  /// No description provided for @booksSearching.
  ///
  /// In en, this message translates to:
  /// **'Searching…'**
  String get booksSearching;

  /// No description provided for @booksSearchFailed.
  ///
  /// In en, this message translates to:
  /// **'Search failed'**
  String get booksSearchFailed;

  /// No description provided for @booksNothingFound.
  ///
  /// In en, this message translates to:
  /// **'Nothing found'**
  String get booksNothingFound;

  /// No description provided for @booksLanguages.
  ///
  /// In en, this message translates to:
  /// **'Languages'**
  String get booksLanguages;

  /// No description provided for @booksAllLanguages.
  ///
  /// In en, this message translates to:
  /// **'All languages'**
  String get booksAllLanguages;

  /// No description provided for @booksNoInLanguages.
  ///
  /// In en, this message translates to:
  /// **'No books in your languages'**
  String get booksNoInLanguages;

  /// No description provided for @booksSearchAllLanguages.
  ///
  /// In en, this message translates to:
  /// **'Search all languages'**
  String get booksSearchAllLanguages;

  /// No description provided for @booksAdd.
  ///
  /// In en, this message translates to:
  /// **'To shelf'**
  String get booksAdd;

  /// No description provided for @booksAdding.
  ///
  /// In en, this message translates to:
  /// **'Adding…'**
  String get booksAdding;

  /// No description provided for @booksOnShelf.
  ///
  /// In en, this message translates to:
  /// **'On shelf'**
  String get booksOnShelf;

  /// No description provided for @booksListen.
  ///
  /// In en, this message translates to:
  /// **'Listen'**
  String get booksListen;

  /// No description provided for @booksFailureOffline.
  ///
  /// In en, this message translates to:
  /// **'No connection'**
  String get booksFailureOffline;

  /// No description provided for @booksFailureUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Service unavailable'**
  String get booksFailureUnavailable;

  /// No description provided for @booksFailureSearchUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Search unavailable'**
  String get booksFailureSearchUnavailable;

  /// No description provided for @booksFailureExpired.
  ///
  /// In en, this message translates to:
  /// **'Link expired'**
  String get booksFailureExpired;

  /// No description provided for @booksFailureNoSpace.
  ///
  /// In en, this message translates to:
  /// **'Not enough space'**
  String get booksFailureNoSpace;

  /// No description provided for @booksFailureLimit.
  ///
  /// In en, this message translates to:
  /// **'Shelf limit reached'**
  String get booksFailureLimit;

  /// No description provided for @booksFailureNotABook.
  ///
  /// In en, this message translates to:
  /// **'Not an audiobook'**
  String get booksFailureNotABook;

  /// No description provided for @booksFailureNotOnShelf.
  ///
  /// In en, this message translates to:
  /// **'Book not on shelf'**
  String get booksFailureNotOnShelf;

  /// No description provided for @booksFailureSignedOut.
  ///
  /// In en, this message translates to:
  /// **'Sign-in required'**
  String get booksFailureSignedOut;

  /// No description provided for @booksFailureBroken.
  ///
  /// In en, this message translates to:
  /// **'Invalid data'**
  String get booksFailureBroken;

  /// No description provided for @bookPageAddToShelf.
  ///
  /// In en, this message translates to:
  /// **'Add to shelf'**
  String get bookPageAddToShelf;

  /// No description provided for @bookPageAddFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t add to shelf'**
  String get bookPageAddFailed;

  /// No description provided for @bookPageListen.
  ///
  /// In en, this message translates to:
  /// **'Listen'**
  String get bookPageListen;

  /// No description provided for @bookPageContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get bookPageContinue;

  /// No description provided for @bookPageRestart.
  ///
  /// In en, this message translates to:
  /// **'Start over'**
  String get bookPageRestart;

  /// No description provided for @bookPageRemoveFromShelf.
  ///
  /// In en, this message translates to:
  /// **'Remove from shelf'**
  String get bookPageRemoveFromShelf;

  /// No description provided for @bookPageRemoveConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove book from shelf?'**
  String get bookPageRemoveConfirm;

  /// No description provided for @bookPageRemoveYes.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get bookPageRemoveYes;

  /// No description provided for @bookPageCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get bookPageCancel;

  /// No description provided for @bookPageNarrator.
  ///
  /// In en, this message translates to:
  /// **'Narrator'**
  String get bookPageNarrator;

  /// No description provided for @bookPageLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get bookPageLanguage;

  /// No description provided for @bookPageDuration.
  ///
  /// In en, this message translates to:
  /// **'Duration'**
  String get bookPageDuration;

  /// No description provided for @bookPageParts.
  ///
  /// In en, this message translates to:
  /// **'Parts'**
  String get bookPageParts;

  /// No description provided for @bookPageYear.
  ///
  /// In en, this message translates to:
  /// **'Recording year'**
  String get bookPageYear;

  /// No description provided for @bookPagePartsAfterAdding.
  ///
  /// In en, this message translates to:
  /// **'after adding'**
  String get bookPagePartsAfterAdding;

  /// No description provided for @bookPagePartsCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} part} other{{count} parts}}'**
  String bookPagePartsCount(int count);

  /// No description provided for @bookPageGone.
  ///
  /// In en, this message translates to:
  /// **'The book was removed from the shelf on another device'**
  String get bookPageGone;

  /// No description provided for @bookPageToMyShelf.
  ///
  /// In en, this message translates to:
  /// **'To my shelf'**
  String get bookPageToMyShelf;

  /// No description provided for @foreignTabLibrary.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get foreignTabLibrary;

  /// No description provided for @foreignTabFavorites.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get foreignTabFavorites;

  /// No description provided for @foreignLeave.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get foreignLeave;

  /// No description provided for @foreignRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get foreignRetry;

  /// No description provided for @foreignLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load — check your connection'**
  String get foreignLoadFailed;

  /// No description provided for @foreignLikeFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not change the favorite'**
  String get foreignLikeFailed;

  /// No description provided for @foreignAlbums.
  ///
  /// In en, this message translates to:
  /// **'Albums'**
  String get foreignAlbums;

  /// No description provided for @foreignArtists.
  ///
  /// In en, this message translates to:
  /// **'Artists'**
  String get foreignArtists;

  /// No description provided for @foreignFavoritesEmpty.
  ///
  /// In en, this message translates to:
  /// **'No favorite songs yet'**
  String get foreignFavoritesEmpty;

  /// No description provided for @foreignLike.
  ///
  /// In en, this message translates to:
  /// **'Add to favorites'**
  String get foreignLike;

  /// No description provided for @foreignUnlike.
  ///
  /// In en, this message translates to:
  /// **'Remove from favorites'**
  String get foreignUnlike;

  /// No description provided for @foreignBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get foreignBack;

  /// No description provided for @languageName.
  ///
  /// In en, this message translates to:
  /// **'{code, select, ru{Russian} en{English} uk{Ukrainian} de{German} fr{French} es{Spanish} it{Italian} pl{Polish} pt{Portuguese} tr{Turkish} be{Belarusian} zh{Chinese} ja{Japanese} ko{Korean} other{}}'**
  String languageName(String code);

  /// No description provided for @loginErrorBadCode.
  ///
  /// In en, this message translates to:
  /// **'The code did not work: check the name and the code, or ask the admin for a new one'**
  String get loginErrorBadCode;

  /// No description provided for @loginErrorWeakPassword.
  ///
  /// In en, this message translates to:
  /// **'The password needs 8 or more characters'**
  String get loginErrorWeakPassword;

  /// No description provided for @loginHaveCode.
  ///
  /// In en, this message translates to:
  /// **'First sign-in with a code'**
  String get loginHaveCode;

  /// No description provided for @loginHavePassword.
  ///
  /// In en, this message translates to:
  /// **'I already have a password'**
  String get loginHavePassword;

  /// No description provided for @loginCode.
  ///
  /// In en, this message translates to:
  /// **'Code from the admin'**
  String get loginCode;

  /// No description provided for @loginNewPassword.
  ///
  /// In en, this message translates to:
  /// **'Make up a password (8 or more characters)'**
  String get loginNewPassword;

  /// No description provided for @loginRepeatPassword.
  ///
  /// In en, this message translates to:
  /// **'Repeat the password'**
  String get loginRepeatPassword;

  /// No description provided for @loginPasswordsDiffer.
  ///
  /// In en, this message translates to:
  /// **'The passwords do not match'**
  String get loginPasswordsDiffer;

  /// No description provided for @loginClaim.
  ///
  /// In en, this message translates to:
  /// **'Save the password and sign in'**
  String get loginClaim;

  /// No description provided for @accountChangePassword.
  ///
  /// In en, this message translates to:
  /// **'Change password'**
  String get accountChangePassword;

  /// No description provided for @passwordOld.
  ///
  /// In en, this message translates to:
  /// **'Current password'**
  String get passwordOld;

  /// No description provided for @passwordChanged.
  ///
  /// In en, this message translates to:
  /// **'Password changed. Other devices are signed out'**
  String get passwordChanged;

  /// No description provided for @passwordWrongOld.
  ///
  /// In en, this message translates to:
  /// **'The current password is wrong'**
  String get passwordWrongOld;

  /// No description provided for @passwordFailed.
  ///
  /// In en, this message translates to:
  /// **'The server did not answer. Try again'**
  String get passwordFailed;

  /// No description provided for @passwordSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get passwordSave;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ru':
      return AppLocalizationsRu();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
