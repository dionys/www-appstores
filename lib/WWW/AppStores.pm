package WWW::AppStores;

use strict;
use warnings;

use Exporter qw(import);
use JSON qw(decode_json);
use List::MoreUtils qw(uniq);
use LWP::UserAgent ();
use URI ();


our $VERSION = '0.01';

our @EXPORT = qw(fetch_app_info parse_app_url);


use constant STORE_APPSTORE    => 'appstore';
use constant STORE_MARKETPLACE => 'marketplace';
use constant STORE_PLAY        => 'play';

use constant HOST_APPSTORE     => 'itunes.apple.com';
use constant HOST_MARKETPLACE  => 'windowsphone.com';
use constant HOST_PLAY         => 'play.google.com';

use constant URL_APPSTORE        => 'http://itunes.apple.com/en/lookup?id=%s';
use constant URL_MARKETPLACE     => 'http://marketplaceedgeservice.windowsphone.com/v8/catalog/apps/%s/?os=7.0&cc=us&lang=en';
use constant URL_MARKETPLACE_CDN => 'http://cdn.marketplaceimages.windowsphone.com/v8/images/%s?imageType=ws_icon_small';
use constant URL_PLAY            => 'http://play.google.com/store/apps/details?id=%s&hl=en';

use constant PLATFORM_ANDROID   => 'android';
use constant PLATFORM_IPAD      => 'ipad';
use constant PLATFORM_IPHONE    => 'iphone';
use constant PLATFORM_IPODTOUCH => 'ipodtouch';
use constant PLATFORM_WINPHONE  => 'winphone';


our $UA = LWP::UserAgent->new();


sub fetch_app_info {
	my ($url) = @_;

	my ($str, $id) = parse_app_url($url);

	return unless $str;

	if ($str eq STORE_APPSTORE) {
		return _fetch_app_info_from_appstore($id);
	}
	if ($str eq STORE_MARKETPLACE) {
		return _fetch_app_info_from_marketplace($id);
	}
	if ($str eq STORE_PLAY) {
		return _fetch_app_info_from_play($id);
	}

	return;
}

sub _fetch_app_info_from_appstore {
	my ($id) = @_;

	my $res = $UA->get(sprintf(URL_APPSTORE, $id));

	return unless $res->is_success;

	$res = decode_json($res->content);

	return unless ref($res->{results}) eq 'ARRAY' && @{$res->{results}};

	$res = $res->{results}[0];

	# (\d+)x(\d)-75\.png$ - $1 & $2 are widBth & height of image
	$res->{artworkUrl100} =~ s/(mzl\.[^\.]+)(\.png)$/$1.100x100-75$2/;

	return {
		id         => $id,
		bundle_id  => $res->{bundleId},
		store      => STORE_APPSTORE,
		name       => $res->{trackName},
		version    => $res->{version},
		logo       => $res->{artworkUrl100},
		publisher  => $res->{sellerName},
		categories => $res->{genres},
		platforms  => [
			uniq
			sort
			grep { defined }
			map {
				my $dev = lc($_);
				my $res;
				for (PLATFORM_IPAD, PLATFORM_IPHONE, PLATFORM_IPODTOUCH) {
					if (index($dev, $_) == 0) {
						$res = $_;
						last;
					}
				}
				$res;
			} @{$res->{supportedDevices}}
		],
		rating     => $res->{contentAdvisoryRating},
	};
}

sub _fetch_app_info_from_marketplace {
	my ($id) = @_;

	my $res = $UA->get(sprintf(URL_MARKETPLACE, $id));

	return unless $res->is_success;

	$res = $res->content;

	return {
		id         => $id,
		bundle_id  => $id,
		store      => STORE_MARKETPLACE,
		name       => ($res =~ /<a:title\s+type=\"text\">([^<]+)</, undef)[0],
		version    => ($res =~ /<version>([\d\.]+)</, undef)[0],
		logo       =>
			(map { $_ ? sprintf(URL_MARKETPLACE_CDN, $_) : $_ }
			($res =~ /<image><id>urn:uuid:([\da-f\-]+)</, undef)[0]),
		publisher  => ($res =~ /<publisher>([^<]+)</, undef)[0],
		categories => [join(': ',
			map { join(' ', map { $_ eq '+' ? '&' : ucfirst } split(/ /)) }
			$res =~ /<category><id>[^<]+<\/id><title>([^<]+)</g)],
		platforms  => [PLATFORM_WINPHONE],
		rating     => ($res =~ /<rating>([^<]+)</, undef)[0],
	};
}

sub _fetch_app_info_from_play {
	my ($id) = @_;

	my $res = $UA->get(sprintf(URL_PLAY, $id));

	return unless $res->is_success;

	$res = $res->content;

	return {
		id         => $id,
		bundle_id  => $id,
		store      => STORE_PLAY,
		name       => ($res =~ /class=\"document-title\"\s+itemprop=\"name\">\s*<div>([^<]+?)</, undef)[0],
		version    => ($res =~ /itemprop=\"softwareVersion\">\s*([\d\.]+)/, undef)[0],
		logo       => # =w(\d+)$ - $1 is width of image
			(map { my $v = $_; $v =~ s/=w\d+$/=w100/ if $v; $v }
			($res =~ /class=\"cover-image\"\s+src=\"([^\"]+)\"/, undef)[0]),
		publisher  => ($res =~ /class=\"document-subtitle[^>]+>\s*<span\s+itemprop=\"name\">\s*([^<]+?)</, undef)[0],
		categories => [map { s/&amp;/&/; $_ } $res =~ /itemprop=\"genre\">([^<]+)</g],
		platforms  => [PLATFORM_ANDROID],
		rating     => ($res =~ /itemprop=\"contentRating\">\s*([^<]+?)\s*</, undef)[0],
	};
}

sub parse_app_url {
	my ($url) = @_;

	$url = URI->new($url);

	return unless $url->isa('URI::http');

	my $hst = $url->host;

	if ($hst eq HOST_APPSTORE || $hst eq 'www.' . HOST_APPSTORE) {
		my @segs = $url->path_segments;

		return if @segs < 2;
		return if length($segs[-1]) < 3;   # min ('id' . <number>) length
		return (STORE_APPSTORE, substr($segs[-1], 2));
	}
	if ($hst eq HOST_MARKETPLACE || $hst eq 'www.' . HOST_MARKETPLACE) {
		my @segs = $url->path_segments;

		return if @segs < 2;
		return if length($segs[-1]) != 36; # guid length
		return (STORE_MARKETPLACE, $segs[-1]);
	}
	if ($hst eq HOST_PLAY || $hst eq 'www.' . HOST_PLAY) {
		my %pars = $url->query_form;

		return unless $pars{id};
		return (STORE_PLAY, $pars{id});
	}

	return;
}


1;
