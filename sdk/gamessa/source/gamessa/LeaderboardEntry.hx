package gamessa;

/**
	Строка лидерборда (`Client.getLeaderboard`).
*/
typedef LeaderboardEntry = {
	var position:Int;
	var userId:Int;
	var username:String;
	var rating:Int;
	@:optional var wins:Int;
	@:optional var losses:Int;
	@:optional var draws:Int;
}
