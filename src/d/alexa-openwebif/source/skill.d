module skill;

import vibe.d;
import ask.ask;
import openwebif.api;

import amazonlogin;
import texts;
import intents.about, intents.current, intents.movies, intents.recordnow,
	intents.services, intents.sleeptimer, intents.togglemute,
	intents.togglestandby, intents.volume, intents.zap, intents.remotecontrol;

///
final class OpenWebifSkill : AlexaSkill!OpenWebifSkill
{
	private OpenWebifApi apiClient;
	private AmazonLoginApiFactory amazonLoginApiFactory = &createAmazonLoginApi;
	private AmazonLoginApi amazonLoginApi;
	private UserProfile amazonProfile;

	///
	this(string accessToken, string locale)
	{
		import std.conv : to;
		import std.process : environment;
		import std.stdio : stderr;
		import std.string : toLower;
		import vibe.aws.aws : StaticAWSCredentials;
		import vibe.aws.dynamodb : DynamoDB;

		immutable accessKey = environment["ACCESS_KEY"];
		immutable secretKey = environment["SECRET_KEY"];
		immutable awsRegion = environment["AWS_DYNAMODB_REGION"];
		immutable owifTableName = environment["OPENWEBIF_TABLENAME"];
		auto creds = new StaticAWSCredentials(accessKey, secretKey);
		auto ddb = new DynamoDB(awsRegion, creds);
		auto table = ddb.table(owifTableName);
		string baseUrl;
		string dbAccessToken;

		if(runAmazonLogin(accessToken))
		{
			try
			{
				string password;
				string user;
				import std.digest.sha : sha256Of;
				import std.digest.digest : toHexString;
				dbAccessToken = (sha256Of(amazonProfile.user_id)).toHexString();
				auto item = table.get("accessToken", dbAccessToken);
				if ("password" in item)
					password = to!string(item["password"]);
				if ("username" in item)
					user = to!string(item["username"]);
				immutable url = to!string(item["url"]);
				auto urlSplit = url.split("://");
				auto protocol = urlSplit[0];
				auto host = urlSplit[1];

				if (user.length > 0 && password.length > 0)
					baseUrl = format("%s://%s:%s@%s", protocol, user, password, host);
				else if (user.length > 0 && password.length == 0)
					baseUrl = format("%s://%s@%s", protocol, user, host);
				else if (user.length == 0 && password.length == 0)
					baseUrl = format("%s://%s", protocol, host);
			}
			catch (Exception e)
			{
				stderr.writefln("Username: %s with user id: %s and token %s has no entry in db: %s", amazonProfile.name, amazonProfile.user_id, dbAccessToken, e);
			}
			try 
			{
				apiClient = new RestInterfaceClient!OpenWebifApi(baseUrl ~ "/api/");
			}
			catch(Exception e)
			{
				stderr.writefln("Error with URL: %s", baseUrl~"/api/");
			}
		}

		locale = locale.toLower;
		immutable isLangDe = locale == "de-de";

		super(isLangDe ? AlexaText_de : AlexaText_en);
		this.addIntent(new IntentAbout());
		this.addIntent(new IntentCurrent(apiClient));
		this.addIntent(new IntentMovies(apiClient));
		this.addIntent(new IntentRecordNow(apiClient));
		this.addIntent(new IntentServices(apiClient));
		this.addIntent(new IntentSleepTimer(apiClient));
		this.addIntent(new IntentToggleMute(apiClient));
		this.addIntent(new IntentToggleStandby(apiClient));
		this.addIntent(new IntentVolumeUp(apiClient));
		this.addIntent(new IntentVolumeDown(apiClient));
		this.addIntent(new IntentSetVolume(apiClient));
		this.addIntent(new IntentZapTo(apiClient));
		this.addIntent(new IntentZapUp(apiClient));
		this.addIntent(new IntentZapDown(apiClient));
		this.addIntent(new IntentZapRandom(apiClient));
		this.addIntent(new IntentZapToEvent(apiClient));
		this.addIntent(new IntentRCPlayPause(apiClient));
		this.addIntent(new IntentRCStop(apiClient));
		this.addIntent(new IntentRCPrevious(apiClient));
	}

	///
	override AlexaResult onLaunch(AlexaEvent event, AlexaContext)
	{
		import std.stdio : stderr;
		AlexaResult result;
		result.response.card.title = getText(TextId.DefaultCardTitle);

		if (!(runAmazonLogin(event.session.user.accessToken)))
		{
			result.response.card.content = getText(TextId.PleaseLogin);
			result.response.card.type = AlexaCard.Type.LinkAccount;
			result.response.outputSpeech.type = AlexaOutputSpeech.Type.SSML;
			result.response.outputSpeech.ssml = getText(TextId.PleaseLoginSSML);
		}
		else
		{
			stderr.writefln("user: %s", amazonProfile);

			result.response.card.content = format(getText(TextId.HelloCardContent),
					amazonProfile.name);
			result.response.outputSpeech.type = AlexaOutputSpeech.Type.SSML;
			result.response.outputSpeech.ssml = .format(getText(TextId.HelloSSML),
					amazonProfile.name);
		}

		return result;
	}

	///
	unittest
	{
		import std.algorithm.searching : canFind;

		auto skill = new OpenWebifSkill("", "de-DE");
		AlexaEvent ev;
		auto resp = skill.onLaunch(ev, AlexaContext.init);
		assert(resp.response.card.type == AlexaCard.Type.LinkAccount);

		skill.amazonLoginApiFactory = cast(AmazonLoginApiFactory)() {
			return new class AmazonLoginApi
			{
				TokenInfo tokeninfo(string)
				{
					return TokenInfo();
				}

				UserProfile profile()
				{
					return UserProfile("foobar123");
				}
			};
		};

		ev.session.user.accessToken = "nonempty";
		resp = skill.onLaunch(ev, AlexaContext.init);
		assert(resp.response.card.type != AlexaCard.Type.LinkAccount);
		assert(canFind(resp.response.card.content, "foobar123"));
	}

	///
	bool runAmazonLogin(string _accessToken)
	{
		if (_accessToken.length == 0)
		{
			return false;
		}
		else
		{
			amazonLoginApi = amazonLoginApiFactory(_accessToken);

			import std.stdio : stderr;

			try
			{
				immutable tokenInfo = amazonLoginApi.tokeninfo(_accessToken);
				amazonProfile = amazonLoginApi.profile();
			}
			catch (Exception e)
			{
				stderr.writefln("tokenInfo parsing error: %s", e);
				return false;
			}
		}
		return true;
	}
}

///
static ServicesList removeMarkers(ServicesList _list)
{
	import std.algorithm.mutation : remove;

	auto i = 0;
	while (i < _list.services[0].subservices.length)
	{
		if (_list.services[0].subservices[i].servicereference.endsWith(
				_list.services[0].subservices[i].servicename))
		{
			_list.services[0].subservices = remove(_list.services[0].subservices, i);
			continue;
		}
		i++;
	}
	return _list;
}

//TODO: move to baselib
unittest
{
	auto skill = new OpenWebifSkill("", "de-DE");
	assert(skill.getText(TextId.PleaseLogin) == AlexaText_de[TextId.PleaseLogin].text);
	skill = new OpenWebifSkill("", "en-US");
	assert(skill.getText(TextId.PleaseLogin) == AlexaText_en[TextId.PleaseLogin].text);
}

AlexaResult returnError(ITextManager texts)
{
	import std.format : format;
	import std.random : uniform;
	import std.conv : to;

	AlexaResult result;
	auto errorId = uniform!uint();
	result.response.card.title = texts.getText(TextId.ErrorCardTitle);
	result.response.card.content = format(texts.getText(TextId.ErrorCardContent),to!string(errorId));
	result.response.outputSpeech.type = AlexaOutputSpeech.Type.SSML;
	result.response.outputSpeech.ssml = texts.getText(TextId.ErrorSSML);
	return result;
}
