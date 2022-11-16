#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Encode;
use YAML;

my $config_file = 'bookscan_dl.yml';
my $download_list_file = 'bookscan_dl-downloaded.yml';

sub main {
	if ( ! -e $config_file ) {
		YAML::DumpFile($config_file, config_file_template());
		print "config file template created at $config_file.\n";
		exit(0);
	}
	my $config = YAML::LoadFile($config_file);
	
	my $local_path = $config->{local}->{path};
	-d $local_path && -w $local_path
		or (print "config local.path directory is not exists or writable:" . Encode::encode('utf8', $local_path)), exit(-1);
	
	my $bd = Bookscan::Downloader->new(
		$download_list_file,
		$config->{ua},
		$config->{bookscan}->{account}, $config->{bookscan}->{password},
	);
	
	$bd->start(
		$local_path
	);
}

sub config_file_template {
	return {
		bookscan => {
			account => '### your bookscan account (email address) ###',
			password => '### your bookscan password ###'
		},
		ua => 'Mozilla/4.0 (compatible; MSIE 8.0; Windows NT 5.1; Trident/4.0)',
		local => {
			path => '### the path to download book file. ###',
		},
	};
}


package Bookscan::Downloader;

use WWW::Mechanize;
use Encode;
use URI::Escape;
use YAML;
use File::Spec;
use Unicode::Normalize;
use File::Copy;
use File::Temp;
use Encode::UTF8Mac;

# re-download limit in seconds (10days)
my $download_limit = 10 * 24 * 60 * 60;

sub report(@) {
	print map { Encode::encode('utf8', $_) } @_, "\n";
}
sub error(@) {
	print STDERR map { Encode::encode('utf8', $_) } @_, "\n";
}
sub abort(@) {
	error(@_);
	exit(-1);
}

sub new {
	my $class = shift;
	my ($downloaded_file, $ua_name, $account, $password) = @_;
	my $ua = WWW::Mechanize->new(
		autocheck => 1,
		agent => $ua_name,
	);
	my $self = bless {
		downloaded_file => $downloaded_file,
		ua => $ua,
		account => $account,
		password => $password,
	}, $class;
	$self->load_downloaded_list();
	
	return $self;
}

sub load_downloaded_list {
	my $self = shift;
	$self->{downloaded} = -e $self->{downloaded_file} ? YAML::LoadFile($self->{downloaded_file}) : {};
}

sub save_downloaded_list {
	my $self = shift;
	if (defined $self->{downloaded}) {
		YAML::DumpFile($self->{downloaded_file}, $self->{downloaded});
	}
}

# WWW::Mechanize::Link オブジェクトから本の名前を抽出
sub namefromlink {
	my $link = shift;
	foreach (split /[\?\&]/, $link->url) {
		my ($k, $v) = split /=/, $_, 2;
		if (defined $k && defined $v && $k eq 'f') {
			# なぜか2回エンコードされている
			return NFC Encode::decode_utf8 uri_unescape uri_unescape $v;
		}
	}
	return undef;
}

# ファイルパスからそのサイズを返す
sub filesizeof {
	my $path = shift;
	return (stat $path)[7];
}

# 衝突しない書籍ファイルパスを作る
sub pathforbook {
	my $dir = shift;
	my $name = shift;
	my $ext = '.pdf';
	if ($name =~ s/(\.\w+)$//) {
		$ext = $1;
	}
	my $suffix = '';
	my $count = 1;
	while ($count < 10000) {
		my $path = File::Spec->catfile($dir, $name . $suffix . $ext);
		if (! -e Encode::encode('utf-8-mac', $path)) {
			return $path;
		}
		$count += 1;
		$suffix = " $count";
	}
	return undef;
}

# status completed: { size => REMOTE_SIZE, timestamp => TIMESTAMP }
# status ignore entry: 'ignore'

sub start {
	my $self = shift;
	my $local_path = shift;
	my $now = time();
	
	$self->login();
	
	my @links = $self->fetch_list_and_find_links();
	foreach my $link (@links) {
		my $name = namefromlink($link);
		defined $name or (report 'no name extracted from link: ', $link->url), next;
		my $download_url;
		my $reason = 'new';
		
		my $status = $self->{downloaded}->{$name};
		if (defined $status) {
			# 再ダウンロード条件をチェック
			if (ref $status) {
				if ($now - $status->{timestamp} > $download_limit) { next } # 再ダウンロード期限を過ぎてたら無視
				$download_url = $self->fetch_download_url($link);
				defined $download_url or next;
				my $size = $self->fetch_download_size($download_url);
				defined $size or next;
				if ($size == $status->{size}) { next } # サイズが同一だったら再ダウンロードしない
				$reason = 'changed';
			} elsif ($status eq 'ignore') {
				next; # status がハッシュではなく文字列 ignore の場合、該当ファイルを無視
			}
		}
		
		# ダウンロード開始
		if (! defined $download_url) {
			$download_url = $self->fetch_download_url($link);
		}
		defined $download_url or next;
		
		report "$name ($reason)";
		$self->download_book($name, $download_url, $local_path);
	}
}

sub login {
	my $self = shift;
	my $login_url = 'https://system.bookscan.co.jp/mypage/login.php';
	
	$self->{ua}->get( $login_url );
	abort 'no login form: ', YAML::Dump($self->{ua}->response) unless $self->{ua}->success;
	
	$self->{ua}->submit_form(
		form_number => 1,
		fields => { email => $self->{account}, password => $self->{password} }
	);
	abort 'login failed: ', YAML::Dump($self->{ua}->response) unless $self->{ua}->success && $self->{ua}->uri ne $login_url;
}

sub fetch_list_and_find_links {
	my $self = shift;
	my $list_url = 'https://system.bookscan.co.jp/mypage/bookshelf_all_list.php';
	
	if ($self->{ua}->uri ne $list_url) {
		$self->{ua}->get( $list_url );
		abort 'fetching book list failed: ', YAML::Dump($self->{ua}->response) unless $self->{ua}->success;
	}
	return $self->{ua}->find_all_links(url_regex => qr'/mypage/showbook.php\?');
}

sub fetch_download_url {
	my $self = shift;
	my $link = shift;
	
	# fetch detail
	$self->{ua}->get( $link->url_abs );
	$self->{ua}->success
		or (report 'fetching download url failed: ',  YAML::Dump($self->{ua}->response)), return undef;
	
	# forbid auto redirect following
	my $redirectable_methods = $self->{ua}->requests_redirectable;
	$self->{ua}->requests_redirectable([]);
	
	# follow link and fetch redirection from detail
	$self->{ua}->follow_link( url_regex => qr'/download.php\?' );
	
	# revert redirect setting
	$self->{ua}->requests_redirectable($redirectable_methods);
	
	$self->{ua}->status eq '302'
		or (report 'No redirection supporsed from download link: ',  YAML::Dump($self->{ua}->response)), return undef;
	my $download_url = $self->{ua}->response->header('Location');
	defined $download_url
		or (report 'No redirect Location header from download link: ' . YAML::Dump($self->{ua}->response)), return undef;
	
	return $download_url;
}

sub fetch_download_size {
	my $self = shift;
	my $download_url = shift;
	
	$self->{ua}->head( $download_url );
	$self->{ua}->success
		or (report 'Fetching file size failed: ', YAML::Dump($self->{ua}->response)), return undef;
	
	my $size = $self->{ua}->response->header('Content-Length');
	defined $size
		or (report 'No Content-Length header from download url: ', YAML::Dump($self->{ua}->response)), return undef;
	
	return $size;
}

sub download_book {
	my $self = shift;
	my $name = shift;
	my $download_url = shift;
	my $local_dir_path = shift;
	
	my $temppath = tmpnam();
	$self->{ua}->get($download_url, ':content_file' => $temppath);
	$self->{ua}->success
		or (report '\tdownload failed:', Dumper($self->{ua}->response)), return 0;
	
	my $remote_size = $self->{ua}->response->header('Content-Length');
	my $local_size = filesizeof($temppath);
	
	if ($remote_size != $local_size) {
		report "\tdownload stop with wrong file size (downloaded: $local_size / expected: $remote_size)";
		return 0;
	}
	
	my $server_specified_filename = parse_filename($self->{ua}->response->header("Content-Disposition"));
	$server_specified_filename
		or (report "\tno filename extracted from header: ", $self->{ua}->response->header("Content-Disposition")), return 0;
	my $local_book_path = pathforbook($local_dir_path, $server_specified_filename);
	if (! defined $local_book_path) {
		report "\tcannot determine local path for $local_dir_path, $server_specified_filename";
		return 0;
	}
	
	if (!File::Copy::move($temppath, Encode::encode('utf-8-mac', $local_book_path))) {
		report "\tdownload completed but failed renaming file from $temppath to $local_book_path.\n";
		return 0;
	}
	
	$self->{downloaded}->{$name} = {
		size => $remote_size,
		timestamp => time(),
	};
	$self->save_downloaded_list();
	
	return 1;
}

# parse filename from Content-Disposition header.
# Content-Disposition: attachment; filename*=UTF-8''<PERCENT_ENCODED_FILENAME.pdf>
sub parse_filename {
	my $header = shift;
	my %arguments = map { my ($k, $v) = split /=/, $_, 2; ($k, $v) } split /; */, $header;
	if (exists $arguments{'filename*'}) {
		if ($arguments{'filename*'} =~ /^(.*)''(.*)$/) {
			return Encode::decode $1, uri_unescape($2);
		} else {
			return Encode::decode('utf8', uri_unescape($arguments{'filename*'}));
		}
	} elsif (exists $arguments{'filename'}) {
		return Encode::decode('utf8', uri_unescape($arguments{'filename'}));
	}
	return undef;
}


package main;
main();
