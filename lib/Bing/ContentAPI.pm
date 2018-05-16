##############################################################################
# Bing::ContentAPI
#
# Add, modify and delete items from the Bing Merchant Center platform via
# the Bing Ads Content API.
#
# https://docs.microsoft.com/bingads/shopping-content/
#
# Authentication is done via OAuth using Authorization Code Grant Flow
# https://docs.microsoft.com/bingads/guides/authentication-oauth
#
# AUTHOR
#
# Bill Gerrard <bill@gerrard.org>
#
# VERSION HISTORY
#
# + v1.00       05/04/2018 initial release
#
# COPYRIGHT AND LICENSE
#
# Copyright (C) 2018 Bill Gerrard
#
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself, either Perl version 5.20.2 or,
# at your option, any later version of Perl 5 you may have available.
#
# Disclaimer of warranty: This program is provided by the copyright holder
# and contributors "As is" and without any express or implied warranties.
# The implied warranties of merchantability, fitness for a particular purpose,
# or non-infringement are disclaimed to the extent permitted by your local
# law. Unless required by law, no copyright holder or contributor will be
# liable for any direct, indirect, incidental, or consequential damages
# arising in any way out of the use of the package, even if advised of the
# possibility of such damage.
#
################################################################################

package Bing::ContentAPI;

use strict;
use warnings;
use Carp;

use JSON;
use REST::Client;
use HTML::Entities;

our $VERSION = '1.00';

sub new {
    my ($class, $param) = @_;
    my $self = {};

    foreach my $val (qw(merchant_id developer_token client_id redirect_uri refresh_token)) {
        $self->{$val} = $param->{$val} || croak "param '$val' missing in new()";
    }

    $self->{debug} = 1 if $param->{debug};

    refresh_access_token($self); # sets access_token, refresh_token

    $self->{rest} = init_rest_client($self);

    return bless $self, $class;
}

sub get {
    my $self = shift;
    croak "Odd number of arguments for get()" if scalar(@_) % 2;
    my $opt = {@_};
    my $method = $self->prepare_method($opt);
    return $self->request('GET', $method);
}

sub post {
    my $self = shift;
    croak "Odd number of arguments for post()" if scalar(@_) % 2;
    my $opt = {@_};
    my $method = $self->prepare_method($opt);
    $opt->{body} = encode_json $opt->{body} if $opt->{body};
    return $self->request('POST', $method, $opt->{body});
}

sub delete {
    my $self = shift;
    croak "Odd number of arguments for delete()" if scalar(@_) % 2;
    my $opt = {@_};
    my $method = $self->prepare_method($opt);
    return $self->request('DELETE', $method);
}

sub prepare_method {
  my $self = shift;
  my $opt = shift;

  $opt->{resource} = '' if $opt->{resource} eq 'custom';

  if ($opt->{resource} eq 'products' || $opt->{resource} eq 'catalogs'
    ) {
    # add merchant ID to request URL
    $opt->{resource} = $self->{merchant_id} .'/'. $opt->{resource};

    # drop list/insert methods; these are for coding convenience only
    $opt->{method} = '' if $opt->{method} eq 'list';
    $opt->{method} = '' if $opt->{method} eq 'insert';

    # insert catalog ID to request URL for status
    $opt->{method} = $opt->{id} .'/'. $opt->{method} if $opt->{method} eq 'status';

    # append product ID to end of request URL for get and delete
    $opt->{method} = $opt->{id} if $opt->{method} =~ /get|delete/;
  }

  push @{$opt->{params}}, ('dry-run','1') if $opt->{dryrun};
  my $encoded_params = $self->{rest}->buildQuery($opt->{params}) if $opt->{params};

  my $method;
  $method .= '/'. $opt->{resource} if $opt->{resource} ne '';
  $method .= '/'. $opt->{method} if $opt->{method} ne '';
  $method .= $encoded_params if $encoded_params;

  return $method;
}

sub init_rest_client {
    my $self = shift;
    my $r = REST::Client->new();
    ### https://docs.microsoft.com/bingads/shopping-content/manage-products
    $r->setHost('https://content.api.bingads.microsoft.com/shopping/v9.1/bmc');
    $r->addHeader('AuthenticationToken', $self->{access_token});
    $r->addHeader('DeveloperToken', $self->{developer_token});
    $r->addHeader('Content-type', 'application/json');
    $r->addHeader('charset', 'UTF-8');
    return $r;
}

my $refresh_token_info = qq|################################################################################
This error may be caused by an invalid refresh token. Follow the procedure
to authorize app and obtain a valid refresh token.
https://docs.microsoft.com/bingads/guides/authentication-oauth#authorizationcode
################################################################################
\n|;

sub request {
    my $self = shift;
    my @command = @_;

    print join (' ', @command) . "\n" if $self->{debug};
    my $rest = $self->{rest}->request(@command);

    unless ($rest->responseCode eq '200') {
        if ($rest->responseCode eq '204' && $command[0] eq 'DELETE') {
          # no-op: delete was successful
      } elsif ($rest->responseCode eq '109') {
            # AuthenticationTokenExpired error code (109), request new refresh token
            $self->refresh_access_token();
            $self->{rest} = $self->init_rest_client();
            $rest = $self->{rest}->request(@command);
        } else {
            my $auth_error = ($rest->responseCode ne '401') ? '' : $refresh_token_info;
            die("${auth_error}Error processing REST request:\n",
                "Request: ", $rest->getHost , $command[1], "\n",
                "Response Code: ", $rest->responseCode, "\n", $rest->responseContent, "\n");
        }
    }
    print "Request Response: \n". $rest->responseContent if $self->{debug};

    my $response = $rest->responseContent ? decode_json $rest->responseContent : {};
    return { code => $rest->responseCode, response => $response };
}

sub get_access_token {
    my $self = shift;
    croak "Odd number of arguments for get_access_token()" if scalar(@_) % 2;
    my $opt = {@_};

    my $bapiTokenURI = 'https://login.live.com/oauth20_token.srf';

    croak "missing grant_type" unless $opt->{grant_type}
        || $opt->{grant_type} eq 'authorization_code'
        || $opt->{grant_type} eq 'refresh_token';

    if ($opt->{grant_type} eq 'authorization_code') {
        $opt->{ctype} = 'code';
        $opt->{cval} = $opt->{code} || '';
    } else {
        $opt->{ctype} = 'refresh_token';
        $opt->{cval} = $opt->{refresh_token} || '';
    }

    my $ua = LWP::UserAgent->new();
    my $response = $ua->post($bapiTokenURI, {
        client_id => $self->{client_id},
        redirect_uri => $self->{redirect_uri},
        grant_type => $opt->{grant_type},
        $opt->{ctype} => $opt->{cval},
    });

    use Data::Dumper;
    print Dumper $response;
    die;
}

sub refresh_access_token {
    my $self = shift;
#    foreach my $val (qw(client_id redirect_uri refresh_token)) {
#        $self->{$val} && $self->{$val} ne '' || croak "'$val' not defined for refresh_access_token()";
#    }

    my $bapiTokenURI = 'https://login.live.com/oauth20_token.srf';

    my $ua = LWP::UserAgent->new();
    my $response = $ua->post($bapiTokenURI, {
        grant_type => 'refresh_token',
        client_id => $self->{client_id},
        redirect_uri => $self->{redirect_uri},
        refresh_token => $self->{refresh_token},
    });

    unless($response->is_success()) {
        die("Error receiving access token:\n", $response->code, "\n", $response->content, "\n");
    }

    my $data = decode_json $response->content;
    $self->{access_token} = $data->{access_token};
    $self->{refresh_token} = $data->{refresh_token};
}

1;

__END__
=head1 NAME

  Bing::ContentAPI - Perl interface to the Bing Ads Content API

=head1 DESCRIPTION

  Add, modify and delete items from the Bing Merchant Center platform via
  the Bing Ads Content API.

  https://docs.microsoft.com/bingads/shopping-content/

  Authentication is done via OAuth using Authorization Code Grant Flow
  https://docs.microsoft.com/bingads/guides/authentication-oauth

=head1 SYNOPSIS

  use Bing::ContentAPI;
  use Data::Dumper;

  my $bing = Bing::ContentAPI->new({
    debug => 0,
    redirect_uri    => 'https://login.live.com/oauth20_desktop.srf',
    merchant_id     => '12345',          # merchant_id is the BMC store ID
    developer_token => '123ABC456DEF789',
    client_id       => '1234abcd-5679-efgh-123456789',
    refresh_token   => load_token(),   # previously saved refresh token
  });
  save_token($bing->{refresh_token}); # save new refresh token

  sub load_token {
    my $token;
    # load token from storage
    return $token;
  }

  sub save_token {
    my $token = shift;
    # save token to storage
  }

  my ($request, $result, $products, $batch_id, $product_id);

  # list products

  my $nextPageToken = '';
  do {
    $request = {
      resource => 'products',
      method   => 'list',
      params   => ['max-results' => 250],
    };
    push @{$request->{params}}, ('start-token', "$nextPageToken") if $nextPageToken ne '';

    $result = $bing->get(%$request);
    $nextPageToken = $result->{response}->{nextPageToken} || '';

    print "$result->{code} ". ($result->{code} eq '200' ? 'success' : 'failure') ."\n";
    print "Products list: \n". Dumper $result;
  } while ($nextPageToken ne '');

  # list catalogs

  $result = $bing->get(
    resource => 'catalogs',
    method   => 'list',
  );
  print "$result->{code} ". ($result->{code} eq '200' ? 'success' : 'failure') ."\n";
  print "Catalogs list: \n". Dumper $result;

  # get status of product offers in a catalog

  my $catalogID = 123456;
  $result = $bing->get(
    resource => 'catalogs',
    method   => 'status',
    id       => $catalogID,
  );
  print "$result->{code} ". ($result->{code} eq '200' ? 'success' : 'failure') ."\n";
  print "Catalog status: \n". Dumper $result;

  # insert a product

  $result = $bing->post(
    resource => 'products',
    method   => 'insert',
    dryrun   => 1,
    body => {
      contentLanguage => 'en',
      targetCountry => 'US',
      channel => 'online',
      offerId => '333333',
      title => 'Item title',
      description => 'The item description',
      link => 'http://www.bing.com',
      imageLink => 'https://img-prod-cms-rt-microsoft-com.akamaized.net/cms/api/am/imageFileData/RE1Mu3b',
      availability => 'in stock',
      condition => 'new',
      price => {
          value => '99.95',
          currency => 'USD',
      },
      shipping => [
        {
          country => 'US',
          service => 'Standard Shipping',
          price => {
            value => '7.95',
            currency => 'USD',
          },
        },
      ],
      brand => 'Apple',
      gtin => '33333367890',
      mpn => '333333',
      googleProductCategory => 'Home & Garden > Household Supplies > Household Paper Products > Paper Towels',
      productType => 'Home & Garden > Household Supplies > Household Paper Products > Paper Towels',
      customLabel1 => 'Paper Towels'
    }
  );
  print "$result->{code} ". ($result->{code} eq '200' ? 'success' : 'failure') ."\n";

  # get single product info

  $product_id = '333333';
  $result = $bing->get(
    resource => 'products',
    method   => 'get',
    id       => 'online:en:US:'. $product_id
  );
  print "$result->{code} ". ($result->{code} eq '200' ? 'success' : 'failure') ."\n";
  print "Products info: \n". Dumper $result;

  # delete a product

  print "product delete: ";

  my $del_product_id = '333333';
  $result = $bing->delete(
    resource => 'products',
    method   => 'delete',
    id       => 'online:en:US:'. $del_product_id,
    dryrun   => 1,
  );
  print "$result->{code} ". ($result->{code} eq '204' ? 'success' : 'failure') ."\n"; # 204 = delete success
  print Dumper $result;

  # batch insert

  $products = [];
  $batch_id = 0;

  foreach my $i ('211203'..'211205') {
    push @$products, {
      batchId => ++$batch_id,
      merchantId => $bing->{merchant_id},
      method => 'insert', # insert / get / delete
      #productId => '', # for get / delete
      product => { # for insert
        contentLanguage => 'en',
        targetCountry => 'US',
        channel => 'online',
        offerId => "$i",
        title => "item title $i",
        description => "The item description for $i",
        link => 'http://www.bing.com',
        imageLink => 'https://img-prod-cms-rt-microsoft-com.akamaized.net/cms/api/am/imageFileData/RE1Mu3b',
        availability => 'in stock',
        condition => 'new',
        price => {
          value => '10.95',
          currency => 'USD',
        },
        shipping => [
          {
            country => 'US',
            service => 'Standard Shipping',
            price => {
              value => '7.95',
              currency => 'USD',
            },
          },
        ],
        brand => 'Apple',
        gtin => "${i}67890",
        mpn => "$i",
        googleProductCategory => 'Home & Garden > Household Supplies > Household Paper Products > Paper Towels',
        productType => 'Home & Garden > Household Supplies > Household Paper Products > Paper Towels',
        customLabel1 => 'Paper Towels'
      }
    };
  }

  $result = $bing->post(
    resource => 'products',
    method   => 'batch',
    dryrun   => 1,
    body => { entries => $products }
  );
  print "$result->{code} ". ($result->{code} eq '200' ? 'success' : 'failure') ."\n";

  # batch get

  $products = [];
  $batch_id = 0;
  foreach my $product_id ('211203'..'211209') {
    push @$products, {
      batchId    => ++$batch_id,
      merchantId => $bing->{merchant_id},
      method     => 'get', # insert / get / delete
      productId  => 'online:en:US:'. $product_id, # for get / delete
    };
  }

  $result = $bing->post(
    resource => 'products',
    method   => 'batch',
    dryrun   => 1,
    body => { entries => $products }
  );
  print "$result->{code} ". ($result->{code} eq '200' ? 'success' : 'failure') ."\n";
  print Dumper $result;

  # batch delete

  $products = [];
  $batch_id = 0;
  foreach my $product_id ('211203'..'211205') {
    push @$products, {
      batchId    => ++$batch_id,
      merchantId => $bing->{merchant_id},
      method     => 'delete', # insert / get / delete
      productId  => 'online:en:US:'. $product_id, # for get / delete
    };
  }

  $result = $bing->post(
    resource => 'products',
    method   => 'batch',
    dryrun   => 1,
    body => { entries => $products }
  );
  print "$result->{code} ". ($result->{code} eq '200' ? 'success' : 'failure') ."\n";

=head1 METHODS AND FUNCTIONS

=head2 new()

  Create a new Bing::ContentAPI object

=head3 debug

  Displays API debug information

=head3 merchant_id

  merchant_id is the Bing Merchant Center Store ID
  https://bingads.microsoft.com/

=head3 developer_token

  Developer token from https://developers.bingads.microsoft.com/Account

=head3 client_id

  Client ID is the value configured in "Registering Your Application":
  https://docs.microsoft.com/bingads/guides/authentication-oauth#registerapplication

=head3 redirect_uri

  If you registered a native application, use "https://login.live.com/oauth20_desktop.srf"
  as the redirect URI. If you registered a web application, use the redirect URI you
  specified in "Registering Your Application".

=head3 refresh_token

  The current refresh token

=head2 refresh_access_token()

  Using the current refresh_token, obtain a new access and refresh token

=head3 access_token

  returns access_token obtained via refresh_access_token()

=head3 refresh_token

  returns refresh_token obtained via refresh_access_token()

=head2 PRODUCTS

=head3 batch

  Retrieves, inserts, and deletes multiple products in a single request.

=head3 insert

  Uploads a product to your Merchant Center account. If an item with the
  same channel, contentLanguage, offerId, and targetCountry already exists,
  this method updates that entry.

=head3 list

  Lists the products in your Merchant Center account.

=head3 get

  Retrieves a product from your Merchant Center account.

=head3 delete

  Deletes a product from your Merchant Center account.

=head2 CATALOGS

=head3 list

  Lists the catalogs in your Merchant Center Account.

=head3 status

  Lists the status and issues of products offers in your Merchant Center Account.

=head1 UNIMPLEMENTED FEATURES

  Certain API methods are not yet implemented (no current personal business need).

  A "custom" resource is available to perform methods that are not implemented by
  this module.

  $result = $bing->get(
    resource => 'custom',
    method   => 'merchantId/orders/orderId'
  );

=head1 PREREQUISITES

  JSON
  REST::Client
  HTML::Entities

=head1 AUTHOR

  Original Author
  Bill Gerrard <bill@gerrard.org>

=head1 COPYRIGHT AND LICENSE

  Copyright (C) 2018 Bill Gerrard

  This library is free software; you can redistribute it and/or modify
  it under the same terms as Perl itself, either Perl version 5.20.2 or,
  at your option, any later version of Perl 5 you may have available.
  Disclaimer of warranty: This program is provided by the copyright holder
  and contributors "As is" and without any express or implied warranties.
  The implied warranties of merchantability, fitness for a particular purpose,
  or non-infringement are disclaimed to the extent permitted by your local
  law. Unless required by law, no copyright holder or contributor will be
  liable for any direct, indirect, incidental, or consequential damages
  arising in any way out of the use of the package, even if advised of the
  possibility of such damage.

=cut
