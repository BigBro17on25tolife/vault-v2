pragma solidity ^0.5.2;
pragma experimental ABIEncoderV2;
import './yToken.sol';

// Contract Templates

contract yTokenLike {
  function mint(address guy, uint wad) public;
  function burn(address guy, uint wad) public;
}

contract DaiLike{
  function transferFrom(address from, address to, uint tokens) public returns (bool);
}

//Using fake contract instead of abstract for mocking
contract Oracle {
  uint256 value;
  function poke(uint256 _value) public {
    value = _value;
  }
  function peek() public view returns (uint256){
    return value;
  }
}
////////////////////////////////////

contract Treasurer {

  struct Repo {
      uint256 locked;   // Locked Collateral  [wad]
      uint256 debt;   // Debt    [wad]
  }

  struct yieldT {
      address where;  // contract address of yToken
      uint256 era;  // maturity time of yToken
  }

  mapping (uint    => yieldT) public yTokens;
  mapping (uint   => mapping (address => Repo)) public repos;
  mapping (address => uint) public gem;  // [wad]
  mapping (uint    => uint) public asset;

  uint must;                        // collateralization ratio [wad]
  uint chop;                        // minimum collateralization [wad]
  //GeneratorLike public generator;
  address recorder;
  address public oracle;
  bytes32 public ilk;
  DaiLike public dai;

  constructor(address generator_, address dai_, uint must_) public {
        //generator = GeneratorLike(Generator_);
        recorder = generator_;
        dai = DaiLike(dai_);
        must = must_;
  }

  // --- Math ---
  uint constant WAD = 10 ** 18;
  uint constant RAY = 10 ** 27;
  function add(uint x, uint y) internal pure returns (uint z) {
      z = x + y;
      require(z >= x, "treasurer-add-z-not-greater-eq-x");
  }
  function sub(uint x, uint y) internal pure returns (uint z) {
      require((z = x - y) <= x, "treasurer-sub-failed");
  }
  function mul(uint x, uint y) internal pure returns (uint z) {
    require(y == 0 || (z = x * y) / y == x,  "treasurer-mul-failed");
  }
  function wmul(uint x, uint y) internal pure returns (uint z) {
    z = add(mul(x, y), WAD / 2) / WAD;
  }
  function wdiv(uint x, uint y) internal pure returns (uint z) {
    z = add(mul(x, WAD), y / 2) / y;
  }

  // --- Views ---

  // return unlocked collateral balance
  function balance(address usr) public view returns (uint){
    return gem[usr];
  }

  // --- Actions ---

  // provide address to oracle
  function set_oracle(address oracle_) external {
    require(msg.sender == recorder);
    oracle = oracle_;
  }

  function peek() public returns (uint r){
    // This oracle has a safety margin built in and should be changed
    Oracle _oracle = Oracle(oracle);
    //require (false, "treasurer-peek-1");
    r= _oracle.peek();
    //require (false, "treasurer-peek-2");
  }

  // issue new yToken
  function issue(uint series, uint256 era) external {
    require(msg.sender == recorder);
    yToken _token = new yToken(era);
    address _a = address(_token);
    yieldT memory yT = yieldT(_a, era);
    yTokens[series] = yT;
  }

  // add collateral to repo
  function join() external payable {
    require(msg.value >= 0, "treasurer-join-must-include-deposit");
    gem[msg.sender] = add(gem[msg.sender], msg.value);
  }

  //remove collateral from repo
  function exit(address payable usr, uint wad) external {
    require(wad >= 0, "treasurer-exit-insufficient-balance");
    gem[msg.sender] = sub(gem[msg.sender], wad);
    usr.transfer(wad);
  }

  // make a new yToken
  // series - yToken to mint
  // made   - amount of yToken to mint
  // paid   - amount of collateral to lock up
  function make( uint series, uint made, uint paid) external {
    Repo memory repo        = repos[series][msg.sender];
    uint rate               = peek(); // to add rate getter!!!
    uint256 min             = wmul(wmul(made, must), rate);
    require (paid >= min, "treasurer-make-insufficient-collateral-for-those-tokens");

    // lock msg.sender Collateral, add debt
    require(gem[msg.sender] >= paid, "treasurer-make-insufficient-collateral-to-lock");
    gem[msg.sender]           = sub(gem[msg.sender], paid);
    repo.locked               = add(repo.locked, paid);
    repo.debt                 = add(repo.debt, made);
    repos[series][msg.sender] = repo;

    // mint new yTokens
    // first, ensure yToken is initialized and matures in the future
    require(yTokens[series].era > now, "treasurer-make-invalid-or-matured-ytoken");
    yTokenLike yT  = yTokenLike(yTokens[series].where);
    address sender = msg.sender;
    yT.mint(sender, made);

  }


  // wipe repo debt with yToken
  // series - yToken to mint
  // tears   - amount of yToken to wipe
  // sweat  - amounht of collateral to free
  function wipe(uint series, uint tears, uint sweat) external {
    // if yToken has matured, should call resolve
    require(now < yTokens[series].era, "treasurer-wipe-yToken-has-matured");

    Repo memory repo        = repos[series][msg.sender];
    // if would be undercollateralized after freeing clean, fail
    uint rlocked               = sub(repo.locked, sweat);
    uint rdebt              = sub(repo.debt, tears);
    uint rate               = peek(); // to add rate getter!!!
    uint256 min             = wmul(wmul(rdebt, must), rate);
    require(rlocked > min, "treasurer-wipe-insufficient-remaining-collateral");

    //burn tokens
    yTokenLike yT  = yTokenLike(yTokens[series].where);
    yT.burn(msg.sender, tears);

    // reduce the collateral and the debt
    repo.locked                  = sub(repo.locked, sweat);
    repo.debt                 = sub(repo.debt, tears);
    repos[series][msg.sender] = repo;

    // add collateral back to the gem
    gem[msg.sender] = add(gem[msg.sender], sweat);

  }

  //liquidate a repo
  function bite(uint series, address bum, uint256 amount) external {

    //check that repo is in danger zone
    Repo memory repo        = repos[series][bum];
    uint rate               = peek(); // to add rate getter!!!
    uint256 min             = wmul(wmul(repo.debt, chop), rate);
    require(repo.locked < min, "treasurer-bite-still-safe");

    //burn tokens
    yTokenLike yT  = yTokenLike(yTokens[series].where);
    yT.burn(msg.sender, amount);

    //update repo
    uint256 bitten            = wmul(amount, rate);
    repo.locked                  = sub(repo.locked, bitten);
    repo.debt                 = sub(repo.locked, amount);
    repos[series][bum]        = repo;

    // send bitten funds
    msg.sender.transfer(bitten);
  }

  // pay the Dai debt for a matured yToken by a repo owner
  // must first approve this contract to transfer the Dai
  // series - matured yToken
  // amount    - amount of yToken to close
  function remit(uint series, uint256 amount ) external {
    require(now > yTokens[series].era, "treasurer-remit-yToken-hasnt-matured");
    require(amount > 0, "treasurer-remit-amount-is-zero");

    //transfer Dai and record the presence of Dai for the yToken series
    require(dai.transferFrom(msg.sender, address(this), amount), "treasurer-remit-dai-transfer-failed");
    asset[series]      = add(asset[series], amount);

    //update Debt
    Repo memory repo   = repos[series][msg.sender];
    require(amount < repo.debt, "treasurer-remit-amount-more-than-debt");
    repo.debt          = sub(repo.debt, amount);

  }

  // tender tokens for available Dai
  // series - matured yToken
  // amount - amount of yTokens to redeem
  function redeem(uint series, uint256 amount) external {
    require(asset[series] > amount, "treasurer-redeem-insufficient-dai-balance");
    //burn tokens
    yTokenLike yT  = yTokenLike(yTokens[series].where);
    yT.burn(msg.sender, amount);

    //transfer Dai and record the presence of Dai for the yToken series
    require(dai.transferFrom(address(this), msg.sender, amount), "treasurer-redeem-dai-transfer-failed");
    asset[series]      = sub(asset[series], amount);
  }

  // tender tokens for ETH from repo
  // series - matured yToken
  // holder - address of repo holder
  // amount - amount of yTokens to redeem
  function retrieve(uint series, address holder, uint256 amount) external {

    //burn tokens
    yTokenLike yT  = yTokenLike(yTokens[series].where);
    yT.burn(msg.sender, amount);

    Repo memory repo        = repos[series][holder];
    uint rate               = peek(); // to add rate getter!!!
    uint256 goods           = wdiv(amount, rate);
    require(repo.debt > amount, "treasurer-redeem-redemption-exceeds-repo-debt");
    repo.locked               = sub(repo.locked, goods);
    repos[series][msg.sender] = repo;

    msg.sender.transfer(goods);
  }
}
