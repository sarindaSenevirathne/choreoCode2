import ballerinax/hubspot.crm.contact;
import ballerina/http;
import ballerina/log;
import ballerinax/salesforce as sfdc;
configurable string hubspotToken = ?;
# Represents a subscription.
public type Subscription record {|
  # Subscriber's email.
  string subscriber;
|};
# Represents a unSubscription.
public type UnSubscription record {|
  # UnSubscriber's email.
  string unsubscriber;
|};
# Represents an error.
public type Error record {|
  # Error code
  string code;
  # Error Message
  string message;
|};
# Error response.
public type ErrorResponse record {|
  # Error
  Error 'error;
|};
# Bad Subscription request response.
public type SubscriptionError record {|
  *http:BadRequest;
  # Error Response
  ErrorResponse body;
|};
# Subscription response.
public type Subscribed record {|
  *http:Ok;
|};
# Bad UnSubscription request response.
public type UnSubscriptionError record {|
  *http:BadRequest;
  # Error Response
  ErrorResponse body;
|};
# UnSubscription response.
public type UnSubscribed record {|
  *http:Ok;
|};
# Asgardeo Oauth2.0 token app configs.
configurable OAuth2ClientConfig & readonly asgardeoOAuthConfig = ?;
type OAuth2ClientConfig record {
  string tokenUrl;
  string clientId;
  string clientSecret;
};
# Hubspot client configs.
// configurable OAuth2RefreshTokenGrantConfig & readonly hubspotOAuthConfig = ?;
# Salesforce client configs.
configurable OAuth2RefreshTokenGrantConfig & readonly salesforceOAuthConfig = ?;
configurable string salesforceBaseUrl = ?;
type OAuth2RefreshTokenGrantConfig record {
  string refreshUrl;
  string refreshToken;
  string clientId;
  string clientSecret;
};
string asgardeoBaseUrl = "https://api.asgardeo.io/t/netflicks/";
string scimEndpoint = "scim2/Users";
# A service representing a network-accessible API
# bound to port `9090`.
service / on new http:Listener(9090) {
  resource function post subscribe(@http:Payload Subscription subscription) returns Subscribed|SubscriptionError|error {
      string userGetRequest = scimEndpoint + "?filter=userName+eq+" + subscription.subscriber + "&attributes=id";
      // Extract user id.
      http:Client usersGetEndpoint = check new (asgardeoBaseUrl,
          auth = {
          tokenUrl: asgardeoOAuthConfig.tokenUrl,
          clientId: asgardeoOAuthConfig.clientId,
          clientSecret: asgardeoOAuthConfig.clientSecret,
          scopes: ["internal_user_mgt_list"]
      }
      );
      http:Response userGetResponse = check usersGetEndpoint->get(userGetRequest);
      if (userGetResponse.statusCode == 200) {
          json userSearchResponseJsonPayload = check userGetResponse.getJsonPayload();
          int totalResults = <int>check userSearchResponseJsonPayload.totalResults;
          if (totalResults == 1) {
              json[] users = <json[]>check userSearchResponseJsonPayload.Resources;
              string userID = <string>check users[0].id;
              log:printInfo(userID);
              // Update user subscription status.
              json scimUserUpdatePayload =
                  {
                  "Operations": [
                      {
                          "op": "add",
                          "value": {
                              "urn:scim:wso2:schema": {
                                  "netflicksSubscription": "SUBSCRIBED"
                              }
                          }
                      }
                  ],
                  "schemas": [
                      "urn:ietf:params:scim:api:messages:2.0:PatchOp"
                  ]
              };
              http:Client usersUpdateEndpoint = check new (asgardeoBaseUrl,
                  auth = {
                  tokenUrl: asgardeoOAuthConfig.tokenUrl,
                  clientId: asgardeoOAuthConfig.clientId,
                  clientSecret: asgardeoOAuthConfig.clientSecret,
                  scopes: ["internal_user_mgt_update"]
              }
              );
              http:Response userUpdateResponse = check usersUpdateEndpoint->patch(scimEndpoint + "/" + userID, scimUserUpdatePayload);
              log:printInfo("User updated. status code : " + userUpdateResponse.statusCode.toString());
          }
      }
      // Hubspot
      contact:Client contactEndpoint = check new ({ auth: { token: hubspotToken } });
      contact:PublicObjectSearchRequest searchContact = {
          "filterGroups": [
              {
                  "filters": [
                      {
                          "value": subscription.subscriber,
                          "propertyName": "email",
                          "operator": "EQ"
                      }
                  ]
              }
          ],
          "sorts": [
              "id"
          ],
          "query": "",
          "properties": [
          ],
          "limit": 1,
          "after": 0
      };
      contact:CollectionResponseWithTotalSimplePublicObjectForwardPaging search = check contactEndpoint->search(searchContact);
      log:printInfo("Hubsport search result -" + search.total.toString());
      string contactID = "";
      if (search.total == 1) {
          contact:SimplePublicObject[] contacts = search.results;
          contactID = contacts[0].id;
          log:printInfo(search.toString());
          log:printInfo(contactID.toString());
          log:printInfo("Have a husbpot contact");
      } else {
          log:printInfo("creating a husbpot contact");
          // Create a content in hubspot
          contact:SimplePublicObjectInput contactPayload =
                  {
              "properties": {
                  "email": subscription.subscriber
              }
          };
          contact:SimplePublicObject create = check contactEndpoint->create(contactPayload);
          log:printInfo(create.toString());
          log:printInfo(create.id);
          contactID = create.id;
      }
      // Update lifecysle status.
      contact:SimplePublicObjectInput updatePayload = {
          "properties": {
              "funflicks_member": true
          }
      };
      contact:SimplePublicObject update = check contactEndpoint->update(contactID, updatePayload);
      log:printInfo(update.toString());
      // Activate user account in SalesForce.
      sfdc:Client sfdcClient = check new ({
          baseUrl: salesforceBaseUrl,
          clientConfig: {
              clientId: salesforceOAuthConfig.clientId,
              clientSecret: salesforceOAuthConfig.clientSecret,
              refreshToken: salesforceOAuthConfig.refreshToken,
              refreshUrl: salesforceOAuthConfig.refreshUrl
          }
      });
      string accountGetQuery = "SELECT id FROM Account WHERE name = '" + subscription.subscriber + "'";
      sfdc:SoqlResult getQueryResultResponse = check sfdcClient->getQueryResult(accountGetQuery);
      log:printInfo(getQueryResultResponse.toString());
      log:printInfo(getQueryResultResponse.totalSize.toString());
      string accountId;
      if (getQueryResultResponse.totalSize == 1) {
          json[] accounts = <json[]>check getQueryResultResponse.records.toJson();
          accountId = <string>check accounts[0].Id;
          log:printInfo(accountId);
      } else {
          // Create account.
          json sfAccount = {"Name": subscription.subscriber};
          accountId = check sfdcClient->createRecord("Account", sfAccount);
          log:printInfo(accountId.toString());
      }
      // Update account status to active.
      json activateSFAccountPayload = {"Active__c": "Yes"};
      _ = check sfdcClient->updateAccount(accountId, activateSFAccountPayload);
      return <Subscribed>{};
  }
  resource function post unsubscribe(@http:Payload UnSubscription unSubscription) returns UnSubscribed|UnSubscriptionError|error {
      string userGetRequest = scimEndpoint + "?filter=userName+eq+" + unSubscription.unsubscriber + "&attributes=id";
      // Extract user id.
      http:Client usersGetEndpoint = check new (asgardeoBaseUrl,
          auth = {
          tokenUrl: asgardeoOAuthConfig.tokenUrl,
          clientId: asgardeoOAuthConfig.clientId,
          clientSecret: asgardeoOAuthConfig.clientSecret,
          scopes: ["internal_user_mgt_list"]
      }
      );
      http:Response userGetResponse = check usersGetEndpoint->get(userGetRequest);
      if (userGetResponse.statusCode == 200) {
          json userSearchResponseJsonPayload = check userGetResponse.getJsonPayload();
          int totalResults = <int>check userSearchResponseJsonPayload.totalResults;
          if (totalResults == 1) {
              json[] users = <json[]>check userSearchResponseJsonPayload.Resources;
              string userID = <string>check users[0].id;
              log:printInfo(userID);
              // Update user subscription status.
              json scimUserUpdatePayload =
                  {
                  "Operations": [
                      {
                          "op": "add",
                          "value": {
                              "urn:scim:wso2:schema": {
                                  "netflicksSubscription": "UNSUBSCRIBED"
                              }
                          }
                      }
                  ],
                  "schemas": [
                      "urn:ietf:params:scim:api:messages:2.0:PatchOp"
                  ]
              };
              http:Client usersUpdateEndpoint = check new (asgardeoBaseUrl,
                  auth = {
                  tokenUrl: asgardeoOAuthConfig.tokenUrl,
                  clientId: asgardeoOAuthConfig.clientId,
                  clientSecret: asgardeoOAuthConfig.clientSecret,
                  scopes: ["internal_user_mgt_update"]
              }
              );
              http:Response userUpdateResponse = check usersUpdateEndpoint->patch(scimEndpoint + "/" + userID, scimUserUpdatePayload);
              log:printInfo("User updated. status code : " + userUpdateResponse.statusCode.toString());
          }
      }
      // Hubspot
      contact:Client contactEndpoint = check new ({ auth: { token: hubspotToken } });
      contact:PublicObjectSearchRequest searchContact = {
          "filterGroups": [
              {
                  "filters": [
                      {
                          "value": unSubscription.unsubscriber,
                          "propertyName": "email",
                          "operator": "EQ"
                      }
                  ]
              }
          ],
          "sorts": [
              "id"
          ],
          "query": "",
          "properties": [
          ],
          "limit": 1,
          "after": 0
      };
      contact:CollectionResponseWithTotalSimplePublicObjectForwardPaging search = check contactEndpoint->search(searchContact);
      log:printInfo ( "Hubsport search result -" + search.total.toString());
      string contactID = "";
      if (search .total == 1) {
      contact:SimplePublicObject []contacts = search.results;
      contactID = contacts[0].id;
      log:printInfo (search .toString());
      log:printInfo (contactID .toString());
      log:printInfo ( "Have a husbpot contact") ;
      } else {
          // TODO throw error.
      }
      // Update lifecysle status.
      contact:SimplePublicObjectInput updatePayload = {
          "properties": {
              "funflicks_member": false
          }
      };
      contact:SimplePublicObject update = check contactEndpoint->update(contactID,updatePayload);
      log:printInfo (update .toString());
      // Deactivate Salesforce account.
      sfdc:Client sfdcClient = check new ({
          baseUrl: salesforceBaseUrl,
          clientConfig: {
              clientId: salesforceOAuthConfig.clientId,
              clientSecret: salesforceOAuthConfig.clientSecret,
              refreshToken: salesforceOAuthConfig.refreshToken,
              refreshUrl: salesforceOAuthConfig.refreshUrl
          }
      });
      string accountGetQuery = "SELECT id FROM Account WHERE name = '" + unSubscription.unsubscriber + "'";
      sfdc:SoqlResult getQueryResultResponse = check sfdcClient->getQueryResult(accountGetQuery);
      string accountId = "";
      if (getQueryResultResponse .totalSize == 1) {
          json[] accounts = <json[]>check getQueryResultResponse.records.toJson();
          accountId = <string>check accounts[0].Id;
          log:printInfo(accountId);
      } else  {
              // TODO throw error.
       }
      // Update account status to active.
      json deActivateSFAccountPayload = {"Active__c": "No"};
      _ = check sfdcClient->updateAccount(accountId,deActivateSFAccountPayload);
      return <UnSubscribed> {} ;
      }
}
 
 

