// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @notice Mirrors the source-registry error so offline tests exercise the
///         SAME revert data as the live Base registry (selector-identical).
error ERC721NonexistentToken(uint256 tokenId);

/// @dev Offline stand-in for the non-enumerable ERC-8004 Identity Registry.
///      Mint/burn only — just enough surface for ERC8004Adapter tests.
contract MockERC8004 {
    mapping(uint256 => address) internal _owners;

    event Minted(uint256 indexed tokenId, address indexed to);
    event Burned(uint256 indexed tokenId);

    function mint(uint256 tokenId, address to) external {
        require(to != address(0), "mint to zero");
        require(_owners[tokenId] == address(0), "already exists");
        _owners[tokenId] = to;
        emit Minted(tokenId, to);
    }

    function burn(uint256 tokenId) external {
        if (_owners[tokenId] == address(0)) revert ERC721NonexistentToken(tokenId);
        delete _owners[tokenId];
        emit Burned(tokenId);
    }

    /// @notice Reverts identically to the live registry on unset/burned ids.
    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner_ = _owners[tokenId];
        if (owner_ == address(0)) revert ERC721NonexistentToken(tokenId);
        return owner_;
    }
}
