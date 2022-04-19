import ballerina/http;
import ballerina/mime;
import ballerinax/mysql;
import ballerinax/mysql.driver as _;
import ballerina/log;

configurable string dbuser = ?;
configurable string dbpwd = ?;

# Represents a country
type Country record {
    # Country code
    string code;
    # Common name of the country
    string name;
    # Population of the country
    int population;
    # Longitude and latitude of the country
    decimal[] coordinates;
    # Picture of the national flag in PNG format
    string flagPic;
    # Flag in unicode
    string flag;
};

# Represents a subdivion with in a country
type SubDivision record {
    # subdivision code
    string code;
    # subdivision name
    string name;
};

http:Client flagEndpoint = check new ("https://flagcdn.com");
http:Client countryEndpoint = check new ("https://restcountries.com/");

public mysql:Client mysqlEndpoint = check new (host = "trimbledemo.mysql.database.azure.com", user = dbuser, password = dbpwd, database = "countries");

# API for providing a useful information about countries.
# bound to port `9090`.
service / on new http:Listener(9090) {

    # Returns the summary of a country given the country code
    # + return - a Country or an error 
    resource function get country/[string code]() returns Country|error {
        log:printInfo("get country information for: " + code);

        record {
            string cca2;
            int population;
            decimal[] latlng;
            string flag;
            record {
                string common;
            } name;

        }[] res = check countryEndpoint->get(string `v3.1/alpha/${code}`);

        if res.length() > 0 {
            Country country = {
                code: res[0].cca2,
                name: res[0].name.common,
                coordinates: res[0].latlng,
                population: res[0].population,
                flagPic: string `/country/${res[0].cca2.toLowerAscii()}/flag`,
                flag: res[0].flag
            };
            return country;
        }

        return error("unable to find the country", countrycode = code);
    }

    # Returns the flag in PNG format.
    # + return - picture file or an error
    resource function get country/[string code]/flag(http:Caller caller) returns error? {

        log:printInfo("get country flag for: " + code);

        byte[]|error content = getFlag(code);
        http:Response response = new ();

        if content is error {
            response.statusCode = http:STATUS_INTERNAL_SERVER_ERROR;
            response.setTextPayload(content.message(), mime:TEXT_PLAIN);
        } else {
            response.statusCode = http:STATUS_OK;
            response.setBinaryPayload(content, mime:IMAGE_PNG);

        }

        check caller->respond(response);
    }

    resource function get country/[string code]/subdivisions() returns SubDivision[]|error {

        log:printInfo("get country subdivisions for: " + code);

        stream<SubDivision, error?> queryRowResponse = mysqlEndpoint->query(`select code, name from subdivisions where country = ${code.toUpperAscii()}`);
        SubDivision[] subs = [];
        check from SubDivision result in queryRowResponse
            do {
                subs.push(result);
            };
        return subs;
    }
}

# Utility function to get a flag from 3rd party api
# + countryCode - the country code
# + return - a `byte[]` or an error
function getFlag(string countryCode) returns byte[]|error {
    http:Response res = check flagEndpoint->get("/80x60/" + countryCode + ".png");
    return check res.getBinaryPayload();
}